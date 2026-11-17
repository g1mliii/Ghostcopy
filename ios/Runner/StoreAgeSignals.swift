import Flutter
import Foundation
import StoreKit
import UIKit
#if canImport(DeclaredAgeRange)
import DeclaredAgeRange
#endif
#if canImport(PermissionKit)
import PermissionKit
#endif

/// Apple's Declared Age Range and PermissionKit significant-change consent,
/// for lib/services/store_age_signal_service.dart. Mirrors StoreAgeSignals.kt.
/// See docs/store-age-signals.md.
///
/// The age range goes to Dart for setup and nowhere else: DPLA 3.3.3(P)
/// allows it only for age-appropriate behaviour in this app. Nothing about it
/// is logged or stored. The only thing kept on the device is the parent's
/// answer to each significant-change question, because PermissionKit delivers
/// answers asynchronously, possibly while the app is not in setup.
///
/// Needs the com.apple.developer.declared-age-range entitlement and the iOS
/// 26.4 SDK (Xcode 26.4+) to build. On older iOS every call answers "not
/// shared" / "notRequired", which keeps the self-declared setup.
final class StoreAgeSignals {
  static let shared = StoreAgeSignals()

  private static let channelName = "com.ghostcopy/store_age"
  private static let answersKey = "store_age.significant_change_answers"
  private static let askedKey = "store_age.significant_change_asked"

  private var channel: FlutterMethodChannel?
  private var listening = false

  private init() {}

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "requestAgeSignal":
        Task { @MainActor in result(await self.requestAgeSignal()) }
      case "significantChange":
        let arguments = call.arguments as? [String: Any] ?? [:]
        guard let description = arguments["description"] as? String, !description.isEmpty else {
          result("notRequired")
          return
        }
        let ask = arguments["ask"] as? Bool ?? false
        Task { @MainActor in result(await self.significantChange(description: description, ask: ask)) }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
    listenForParentAnswers()
  }

  // MARK: - Age range

  @MainActor
  private func requestAgeSignal() async -> [String: Any] {
    let notShared: [String: Any] = ["shared": false]
    #if canImport(DeclaredAgeRange)
    guard #available(iOS 26.0, *), let controller = Self.presenter() else { return notShared }
    do {
      // 18 decides adult or parent setup; 13 and 16 narrow a minor's band.
      // The system may move these gates for local regulations.
      let response = try await AgeRangeService.shared.requestAgeRange(ageGates: 13, 16, 18, in: controller)
      guard case let .sharing(range) = response else { return notShared }
      var answer: [String: Any] = [
        "shared": true,
        "store": "app_store",
        "significantChangeConsentRequired": await significantChangeConsentRequired(),
      ]
      if let lower = range.lowerBound { answer["ageLower"] = lower }
      if let upper = range.upperBound {
        answer["ageUpper"] = upper
        // Only a minor's setup needs it: RESCIND_CONSENT names the app
        // transaction, and this is how the server finds the account.
        if upper < 18, let reference = await Self.appTransactionID() { answer["storeRef"] = reference }
      }
      return answer
    } catch {
      // declinedOnboarding, invalidAccount, notAvailable, network...
      return notShared
    }
    #else
    return notShared
    #endif
  }

  private static func appTransactionID() async -> String? {
    guard let verification = try? await AppTransaction.shared,
      case let .verified(transaction) = verification
    else { return nil }
    return transaction.appTransactionID
  }

  // MARK: - Significant change (PermissionKit)

  @MainActor
  private func significantChangeConsentRequired() async -> Bool {
    #if canImport(DeclaredAgeRange)
    if #available(iOS 26.4, *) {
      let features = try? await AgeRangeService.shared.requiredRegulatoryFeatures
      return features?.contains(.significantAppChangeRequiresParentalConsent) ?? false
    }
    #endif
    return false
  }

  /// "approved" / "declined" once the parent answered the question for this
  /// [description]; "pending" while it needs (or awaits) an answer;
  /// "notRequired" where Apple does not require parental consent.
  @MainActor
  private func significantChange(description: String, ask: Bool) async -> String {
    #if canImport(PermissionKit)
    guard #available(iOS 26.2, *) else { return "notRequired" }
    if let answer = Self.answers[description] { return answer }
    guard await significantChangeConsentRequired() else { return "notRequired" }
    if ask, !Self.asked.contains(description), let controller = Self.presenter() {
      do {
        let question = PermissionQuestion(
          significantAppUpdateTopic: SignificantAppUpdateTopic(description: description))
        try await AskCenter.shared.ask(question, in: controller)
        var asked = Self.asked
        asked.insert(description)
        UserDefaults.standard.set(Array(asked), forKey: Self.askedKey)
      } catch AskError.notAvailable {
        // Thrown for adults: nothing for a parent to approve.
        return "notRequired"
      } catch {
        // Cancelled or failed: still pending, and asked again next time.
      }
    }
    return "pending"
    #else
    return "notRequired"
    #endif
  }

  /// Parents answer in Messages or Screen Time, later and maybe while the app
  /// is closed; the system delivers answers through this sequence.
  private func listenForParentAnswers() {
    #if canImport(PermissionKit)
    guard #available(iOS 26.2, *), !listening else { return }
    listening = true
    Task { @MainActor in
      for await response in AskCenter.shared.responses(for: SignificantAppUpdateTopic.self) {
        var answers = Self.answers
        answers[response.question.topic.description] =
          response.choice.id == PermissionChoice.approve.id ? "approved" : "declined"
        UserDefaults.standard.set(answers, forKey: Self.answersKey)
      }
    }
    #endif
  }

  private static var answers: [String: String] {
    UserDefaults.standard.dictionary(forKey: answersKey) as? [String: String] ?? [:]
  }

  private static var asked: Set<String> {
    Set(UserDefaults.standard.stringArray(forKey: askedKey) ?? [])
  }

  @MainActor
  private static func presenter() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }
}
