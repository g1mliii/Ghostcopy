# Google Play: from account to closed test

Developer account purchased 2026-09-15. This is the path from there to a build
in testers' hands.

The long pole is **not** the code. A new personal developer account has to run
a closed test with **20 testers for 14 continuous days** before it can apply for
production access, and the count dropping below 20 restarts the clock. Nothing
else here takes 14 days, so the goal is to get *something* uploadable fast and
let that timer run while other work continues.

> Verify the current rule when you get there — Google has changed the testing
> requirements more than once, and this doc may be stale.

---

## 1. Generate the upload keystore

Do this yourself; it involves passwords. On Windows, `keytool` ships with
Android Studio's bundled JDK:

```bash
"C:/Program Files/Android/Android Studio/jbr/bin/keytool.exe" \
  -genkeypair -v \
  -keystore "$HOME/ghostcopy-upload.jks" \
  -storetype PKCS12 \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias upload
```

`-validity 10000` (~27 years) is the Play convention: an expired upload key is
a problem you do not want to discover later.

**Store it outside the repo** — `$HOME`, not the project directory. Back it up
somewhere you will still have in five years, along with both passwords.

### How bad is losing it?

Less bad than it used to be, but still bad. New apps use **Play App Signing**:
Google holds the real *app signing key*, and what you generate here is only an
*upload key*. If you lose the upload key, Google can reset it after identity
verification — recoverable, but slow and unpleasant. If you ever opt out of
Play App Signing, losing the key means you can never update the app again.

Stay on Play App Signing. It is the default.

---

## 2. Point the build at it

Create `android/key.properties` — gitignored, never committed:

```properties
storePassword=<your store password>
keyPassword=<your key password>
keyAlias=upload
storeFile=C:/Users/<you>/ghostcopy-upload.jks
```

Use forward slashes in `storeFile` even on Windows.

`android/app/build.gradle.kts` already reads this. With the file present the
release build is signed with your upload key; without it the build falls back
to the debug key and logs a warning, so a machine with no keystore can still
run `flutter run --release`. That fallback is deliberate — it keeps development
working, and Play rejecting a debug-signed artifact is the correct outcome.

Verified working on 2026-09-15 with a throwaway keystore: the resulting AAB
carried the throwaway certificate rather than the debug one.

---

## 3. Build the bundle

Play wants an **Android App Bundle**, not an APK:

```bash
flutter build appbundle --release
# build/app/outputs/bundle/release/app-release.aab
```

Confirm it is signed with the right key before uploading:

```bash
unzip -p build/app/outputs/bundle/release/app-release.aab "META-INF/*.RSA" > /tmp/sig.rsa
keytool -printcert -file /tmp/sig.rsa      # Owner should NOT say "Android Debug"
```

**Note:** CI (`.github/workflows/build-check.yml`) builds `apk`, not
`appbundle`, and has no keystore. That is fine — it is a compile check, not a
release pipeline. Do not wire signing secrets into CI until there is a reason.

### Versioning

`pubspec.yaml` is still at the default `version: 1.0.0+1`. The `+1` is the
`versionCode`, and **Play refuses a re-upload of a versionCode it has already
seen** — so every upload needs a bump, even a broken one you immediately
replace. Expect to burn several during setup.

---

## 4. Play Console, first app

Create the app, then work through what Console marks as required. The ones with
real content behind them:

- **Privacy policy URL** — `https://ghostcopy.app/privacy` already exists
- **Data safety** — GhostCopy transmits and stores user clipboard content.
  Declare it honestly: what is collected, that it is encrypted in transit, and
  whether users can request deletion. The app has
  `cleanup_user_data_function`, so deletion-on-request is answerable with a yes.
- **Content rating** — a questionnaire; a utility rates trivially
- **Target audience** — not designed for children (this was already declared at
  signup)
- **App access** — the app requires an account. Console asks how reviewers sign
  in, so provide working credentials or explain the anonymous sign-in flow,
  which needs no credentials at all
- **Store listing** — name, short and full description, feature graphic,
  screenshots. The branding from 2026-09-15 is current; the icon is
  `assets/icons/app_icon.png`

---

## 5. Start the closed test

Upload the AAB to a **closed testing** track, then recruit 20 testers. They must
opt in with the Google account tied to their device and stay opted in for the
full 14 days.

`beta_waitlist` on the website is the natural source — that is what it is for.
Note the mismatch: a waitlist collects email addresses, but Play needs **Google
account** addresses, and an email list is not the same thing. Plan to ask
explicitly.

The 14 days run whether or not you are working on the app, so start this as
early as a build allows.

---

## Order of operations

1. Generate keystore, add `key.properties`, build a signed AAB
2. Create the app in Console, fill the required declarations
3. Upload to closed testing, recruit 20 testers, **start the clock**
4. Everything else — macOS, iOS, polish — happens while it runs

---

## Known gaps

- `version: 1.0.0+1` is untouched; decide a versioning scheme before the first
  upload rather than during it
- The release AAB is ~70MB, which is large for a utility. Play's download size
  is smaller after per-device splits, but worth looking at before launch
- Nothing has ever been uploaded, so none of the Console flow above has been
  walked through in practice — expect surprises
