# Google OAuth Setup Guide for GhostCopy

This guide walks you through setting up Google Sign-In with Supabase for GhostCopy.

## Prerequisites

- A Google Cloud Platform account
- Access to your Supabase project dashboard
- GhostCopy codebase set up locally

## Step 1: Google Cloud Console Setup

### 1.1 Create/Select a Project
1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project or select an existing one
3. Note your Project ID

### 1.2 Configure OAuth Consent Screen
1. Navigate to **APIs & Services > OAuth consent screen**
2. Choose **External** user type (or Internal if using Google Workspace)
3. Fill in the required fields:
   - **App name**: GhostCopy
   - **User support email**: Your email
   - **Developer contact information**: Your email
4. Add the following **OAuth scopes** (REQUIRED):
   - `openid` (add manually)
   - `.../auth/userinfo.email` (added by default)
   - `.../auth/userinfo.profile` (added by default)

   ⚠️ **Important**: Only add these 3 scopes. Adding sensitive/restricted scopes may require Google verification which can take weeks.

5. (Optional but Recommended) Configure branding:
   - Upload app logo
   - Add application homepage
   - Add privacy policy and terms of service URLs
   - **Verify your brand** to show your logo/name instead of "Supabase" in the consent screen

### 1.3 Create OAuth 2.0 Credentials

You'll need to create separate credentials for each platform:

#### Web (Desktop: Windows, macOS, Linux)
1. Go to **APIs & Services > Credentials**
2. Click **Create Credentials > OAuth client ID**
3. Choose **Web application**
4. Name: "GhostCopy Web"
5. Add **Authorized redirect URIs**:
   ```
   https://xhbggxftvnlkotvehwmj.supabase.co/auth/v1/callback
   ```
   (Replace with your actual Supabase project URL)
6. Click **Create** and save the **Client ID**

#### iOS
1. Click **Create Credentials > OAuth client ID**
2. Choose **iOS**
3. Name: "GhostCopy iOS"
4. Bundle ID: `com.yourcompany.ghostcopy` (from ios/Runner/Info.plist)
5. Click **Create** and save the **Client ID**

#### Android
1. Click **Create Credentials > OAuth client ID**
2. Choose **Android**
3. Name: "GhostCopy Android"
4. Package name: `com.yourcompany.ghostcopy` (from android/app/build.gradle)
5. Get SHA-1 fingerprint:
   ```bash
   # For debug builds
   keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android

   # For release builds
   keytool -list -v -keystore /path/to/your/release.keystore -alias your-key-alias
   ```
6. Enter the SHA-1 fingerprint
7. Click **Create** and save the **Client ID**

## Step 2: Supabase Configuration

### 2.1 Enable Google Provider
1. Go to your [Supabase Dashboard](https://supabase.com/dashboard)
2. Select your project: **xhbggxftvnlkotvehwmj**
3. Navigate to **Authentication > Providers**
4. Find **Google** and click to expand
5. Enable the provider
6. Enter your **Web Client ID** (from Google Cloud Console)
7. Enter your **Client Secret** (from Google Cloud Console - Web application credentials)
8. (Optional) Configure additional client IDs:
   - If you have iOS and Android client IDs, add them in the "Additional Client IDs" section
   - Format: Comma-separated list with Web ID first
   ```
   web-client-id.apps.googleusercontent.com,ios-client-id.apps.googleusercontent.com,android-client-id.apps.googleusercontent.com
   ```
9. Click **Save**

### 2.2 Verify Redirect URL
Make sure your redirect URL in Supabase matches what you configured in Google Cloud Console:
- URL: `https://xhbggxftvnlkotvehwmj.supabase.co/auth/v1/callback`

## Step 3: Update GhostCopy Environment Variables

1. Open `.env` file in your project root
2. Update the `GOOGLE_CLIENT_ID` variable:
   ```
   GOOGLE_CLIENT_ID=your-web-client-id-here.apps.googleusercontent.com
   ```
   ⚠️ Use the **Web Client ID** here, not iOS or Android

## Step 4: Configure Deep Linking (Mobile Only)

### iOS Deep Link Setup
1. Open `ios/Runner/Info.plist`
2. Add URL scheme for deep linking:
   ```xml
   <key>CFBundleURLTypes</key>
   <array>
     <dict>
       <key>CFBundleTypeRole</key>
       <string>Editor</string>
       <key>CFBundleURLSchemes</key>
       <array>
         <string>ghostcopy</string>
       </array>
     </dict>
   </array>
   ```

### Android Deep Link Setup
1. Open `android/app/src/main/AndroidManifest.xml`
2. Add intent filter inside the `<activity>` tag:
   ```xml
   <intent-filter>
     <action android:name="android.intent.action.VIEW" />
     <category android:name="android.intent.category.DEFAULT" />
     <category android:name="android.intent.category.BROWSABLE" />
     <data android:scheme="ghostcopy" android:host="auth-callback" />
   </intent-filter>
   ```

## Step 5: Test the Integration

### Desktop Testing
1. Run the app: `flutter run -d windows` (or macos/linux)
2. Open the app and go to Settings > Account
3. Click "Continue with Google"
4. Browser should open for Google sign-in
5. After signing in, you should be redirected back to the app
6. Verify your email appears in the account section

### Mobile Testing
1. Run the app: `flutter run -d android` (or ios)
2. Open the app and navigate to auth screen
3. Tap "Continue with Google"
4. Should open Google sign-in in a browser/webview
5. After authentication, app should reopen automatically via deep link
6. Verify authentication succeeded

## Troubleshooting

### Common Issues

1. **"redirect_uri_mismatch" error**
   - Double-check your redirect URI in Google Cloud Console matches exactly: `https://xhbggxftvnlkotvehwmj.supabase.co/auth/v1/callback`
   - Make sure there are no trailing slashes

2. **"Access blocked: This app's request is invalid"**
   - Verify you've configured the OAuth consent screen
   - Check that you've added the correct scopes (openid, email, profile)

3. **Mobile: App doesn't reopen after Google sign-in**
   - Verify deep linking is configured correctly (check AndroidManifest.xml / Info.plist)
   - Test the deep link manually: `adb shell am start -W -a android.intent.action.VIEW -d "ghostcopy://auth-callback"`

4. **"Client ID not found" error**
   - Make sure you're using the correct Client ID for each platform
   - For desktop, use the Web Client ID
   - Verify the Client ID is correctly set in Supabase dashboard

5. **Sign-in succeeds but user not recognized**
   - Check Supabase dashboard > Authentication > Users to see if user was created
   - Verify RLS policies allow the user to access their data

## Custom Domain (Optional but Recommended)

For better security and user trust, consider setting up a custom domain:

1. In Supabase: **Project Settings > Custom Domains**
2. Add your domain (e.g., `auth.ghostcopy.com`)
3. Update Google Cloud Console redirect URIs to use your custom domain
4. Update deep link configuration if needed

This makes the OAuth consent screen show your domain instead of `xhbggxftvnlkotvehwmj.supabase.co`.

## Security Best Practices

1. **Never commit** `.env` to version control
2. **Rotate credentials** if they're exposed
3. **Use custom domain** for production to prevent phishing
4. **Verify brand** in Google Cloud Console to show your logo
5. **Limit scopes** to only what you need (email + profile)
6. **Enable 2FA** on Google Cloud and Supabase accounts

## References

- [Supabase Google OAuth Documentation](https://supabase.com/docs/guides/auth/social-login/auth-google)
- [Google Cloud OAuth Setup](https://console.cloud.google.com/apis/credentials)
- [Flutter Deep Linking Guide](https://docs.flutter.dev/development/ui/navigation/deep-linking)
