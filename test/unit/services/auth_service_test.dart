import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/auth_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Mock classes
class MockSupabaseClient extends Mock implements SupabaseClient {}

class MockGoTrueClient extends Mock implements GoTrueClient {}

class MockUser extends Mock implements User {}

class MockUserResponse extends Mock implements UserResponse {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSupabaseClient mockClient;
  late MockGoTrueClient mockAuth;
  late AuthService authService;

  setUp(() {
    mockClient = MockSupabaseClient();
    mockAuth = MockGoTrueClient();

    when(() => mockClient.auth).thenReturn(mockAuth);

    authService = AuthService(client: mockClient);
  });

  group('AuthService - Initialization', () {
    test('initialize() signs in anonymously when no user exists', () async {
      when(() => mockAuth.currentUser).thenReturn(null);
      when(() => mockAuth.signInAnonymously()).thenAnswer(
        (_) async => AuthResponse(),
      );

      await authService.initialize();

      verify(() => mockAuth.signInAnonymously()).called(1);
    });

    test('initialize() does not sign in when user already exists', () async {
      final mockUser = MockUser();
      when(() => mockUser.id).thenReturn('existing-user-id');
      when(() => mockUser.isAnonymous).thenReturn(true);
      when(() => mockAuth.currentUser).thenReturn(mockUser);

      await authService.initialize();

      verifyNever(() => mockAuth.signInAnonymously());
    });
  });

  group('AuthService - User State', () {
    test('currentUser returns the current user', () {
      final mockUser = MockUser();
      when(() => mockAuth.currentUser).thenReturn(mockUser);

      expect(authService.currentUser, equals(mockUser));
    });

    test('isAnonymous returns true for anonymous users', () {
      final mockUser = MockUser();
      when(() => mockUser.isAnonymous).thenReturn(true);
      when(() => mockAuth.currentUser).thenReturn(mockUser);

      expect(authService.isAnonymous, isTrue);
    });

    test('isAnonymous returns false for authenticated users', () {
      final mockUser = MockUser();
      when(() => mockUser.isAnonymous).thenReturn(false);
      when(() => mockAuth.currentUser).thenReturn(mockUser);

      expect(authService.isAnonymous, isFalse);
    });

    test('isAnonymous returns true when no user exists', () {
      when(() => mockAuth.currentUser).thenReturn(null);

      expect(authService.isAnonymous, isTrue);
    });
  });

  group('AuthService - Email/Password Authentication', () {
    test('signUpWithEmail creates a new account', () async {
      final mockResponse = AuthResponse(user: MockUser());

      when(
        () => mockAuth.signUp(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      ).thenAnswer((_) async => mockResponse);

      final result =
          await authService.signUpWithEmail('test@example.com', 'password123');

      expect(result, equals(mockResponse));
      verify(
        () => mockAuth.signUp(
          email: 'test@example.com',
          password: 'password123',
        ),
      ).called(1);
    });

    test('signInWithEmail signs in an existing user', () async {
      final mockResponse = AuthResponse(user: MockUser());

      when(
        () => mockAuth.signInWithPassword(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      ).thenAnswer((_) async => mockResponse);

      final result = await authService.signInWithEmail(
        'test@example.com',
        'password123',
      );

      expect(result, equals(mockResponse));
      verify(
        () => mockAuth.signInWithPassword(
          email: 'test@example.com',
          password: 'password123',
        ),
      ).called(1);
    });
  });

  group('AuthService - Anonymous Upgrade', () {
    test('upgradeWithEmail upgrades anonymous user to email account', () async {
      final mockUser = MockUser();
      when(() => mockUser.isAnonymous).thenReturn(true);
      when(() => mockAuth.currentUser).thenReturn(mockUser);

      final mockResponse = MockUserResponse();
      when(() => mockResponse.user).thenReturn(mockUser);

      when(
        () => mockAuth.updateUser(any()),
      ).thenAnswer((_) async => mockResponse);

      final result = await authService.upgradeWithEmail(
        'test@example.com',
        'password123',
      );

      expect(result, equals(mockResponse));
      verify(() => mockAuth.updateUser(any())).called(1);
    });

    test('upgradeWithEmail throws when user is not anonymous', () async {
      final mockUser = MockUser();
      when(() => mockUser.isAnonymous).thenReturn(false);
      when(() => mockAuth.currentUser).thenReturn(mockUser);

      expect(
        () => authService.upgradeWithEmail('test@example.com', 'password123'),
        throwsException,
      );
    });

    test('linkGoogleIdentity links Google OAuth to anonymous user', () async {
      final mockUser = MockUser();
      when(() => mockUser.isAnonymous).thenReturn(true);
      when(() => mockAuth.currentUser).thenReturn(mockUser);

      when(
        () => mockAuth.linkIdentity(OAuthProvider.google),
      ).thenAnswer((_) async => true);

      final result = await authService.linkGoogleIdentity();

      expect(result, isTrue);
      verify(() => mockAuth.linkIdentity(OAuthProvider.google)).called(1);
    });

    test('linkGoogleIdentity throws when user is not anonymous', () async {
      final mockUser = MockUser();
      when(() => mockUser.isAnonymous).thenReturn(false);
      when(() => mockAuth.currentUser).thenReturn(mockUser);

      expect(() => authService.linkGoogleIdentity(), throwsException);
    });
  });

  group('AuthService - Sign Out', () {
    test('signOut signs out user and signs back in anonymously', () async {
      when(() => mockAuth.signOut()).thenAnswer((_) async {});
      when(() => mockAuth.signInAnonymously()).thenAnswer(
        (_) async => AuthResponse(),
      );

      await authService.signOut();

      verify(() => mockAuth.signOut()).called(1);
      verify(() => mockAuth.signInAnonymously()).called(1);
    });
  });

  group('AuthService - Disposal', () {
    test('dispose() cleans up resources', () {
      authService.dispose();
      // No exception should be thrown
    });
  });
}
