# Getting this onto your team's iPhones — no Mac, all from Windows

This is the free, no-Mac path: build the app on GitHub's cloud, install it
onto each iPhone from a Windows PC using Sideloadly. Nobody touches Xcode.

## One-time setup

### 1. Get the code onto GitHub
- Create a **public** repo on github.com (public = free, unlimited Actions
  build minutes; private repos get a much smaller free quota)
- Push this whole `RocklenseAB-iOS` folder to it (GitHub Desktop is the
  easiest way to do this from Windows with no command line — install it,
  "Add local repository," point it at this folder, publish)

### 2. Add your Firebase config as a secret
The build needs `GoogleService-Info.plist`, but that shouldn't be committed
in plain text to a public repo.

- Get the file's base64 text. On Windows, PowerShell:
  ```powershell
  [Convert]::ToBase64String([IO.File]::ReadAllBytes("GoogleService-Info.plist")) | Set-Clipboard
  ```
  (this copies the result straight to your clipboard)
- GitHub repo → **Settings → Secrets and variables → Actions → New repository
  secret**
- Name: `GOOGLE_SERVICE_INFO_PLIST_B64`
- Value: paste what you copied
- Save

### 3. Run the build
- GitHub repo → **Actions** tab → "Build unsigned IPA" workflow → **Run
  workflow** button
- Takes roughly 5–15 minutes (SPM has to fetch Firebase/GoogleSignIn the
  first time)
- When it finishes (green check), click into the run → scroll to
  **Artifacts** → download `RocklenseAB-ipa` → unzip it to get
  `RocklenseAB.ipa`

If it fails instead (red X), click into the failed step to see the error —
paste it here and I'll help sort it out.

## Installing on each iPhone (repeat per person)

### 1. Install Sideloadly on the Windows PC
Download from **sideloadly.io** (Windows build). It'll also prompt you to
install **iTunes** or **Apple Devices** from the Microsoft Store if it's
not already there — needed for the USB drivers, not for actually using
iTunes.

### 2. Connect the iPhone
- Cable it to the PC
- On the phone, tap **Trust This Computer** when prompted

### 3. Sideload the app
- Open Sideloadly
- Drag `RocklenseAB.ipa` into the window (or click the icon and browse to it)
- Enter the Apple ID email in the field — **any free Apple ID works**, it
  doesn't need to be the same one across teammates, and doesn't need a paid
  Developer account
- Click **Start** — it'll ask for the Apple ID password (and a 2FA code if
  that account has it on)
- Wait for it to finish — the app icon appears on the home screen

### 4. Trust the developer profile (first launch only)
The phone will refuse to open the app the first time until you do this:
- **Settings → General → VPN & Device Management**
- Tap the developer profile under it (usually shows the Apple ID email)
- Tap **Trust**
- Now open the app normally

### 5. Know the expiry
Free-account sideloads last **7 days**, then the app just won't open until
re-installed. For a few days of feedback this is a non-issue — if you need
it longer, either re-run the Sideloadly install, or that's the point where
paying for TestFlight starts to make sense.

## What to tell your team about sign-in

Since this isn't signed with a paid account, **Sign in with Apple won't
work** in this build. Have them use **Google sign-in** or **"Continue
without an account"** on the sign-in screen instead — everything else (map,
AR, profiles, friends, reviews) works normally either way.
