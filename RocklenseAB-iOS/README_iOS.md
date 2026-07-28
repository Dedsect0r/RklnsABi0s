# Rocklense AB — iOS

A SwiftUI port of the Rocklense AB Android app: AR clip-finding for sport
climbers, a crag map, and climber profiles/friends — running against the
**same Firebase backend** as the Android app (same Firestore documents, same
Storage files, same security rules, live). A wall mapped on one platform
shows up on the other.

Same honesty policy as the Android README: this is a complete, carefully
structured port written without access to a Mac, so **it has not been
compiled or run**. Expect to fix a handful of small compile errors on first
build (API signatures drift between SDK versions), and read the
"Field-verify the AR axis convention" section before trusting cross-platform
clip positions. The architecture, data compatibility, and AR math are the
carefully-thought-through parts; the exact SDK call spellings are the part a
first build will shake out.

## What's in the box

| Android | iOS | Notes |
|---|---|---|
| Fragments + Navigation graph | SwiftUI + NavigationStack | one View per Fragment, same screen set |
| Google Maps SDK | Apple MapKit | no API key or billing needed |
| ARCore Augmented Images + hand-written GLES renderers | ARKit image tracking + RealityKit | first-party equivalent of each piece |
| CameraX aligned-capture screen | AVFoundation | same ghost-overlay/crosshair UX |
| Google Sign-In + anonymous | Google + **Sign in with Apple** + anonymous | Apple's is required by App Store Guideline 4.8 once Google is offered |
| SharedPreferences per uid | UserDefaults per uid | same per-account scoping |
| google-services.json | GoogleService-Info.plist | both from the same Firebase project |

AR is **optional at runtime** (no `UIRequiredDeviceCapabilities: arkit`):
Map/Profile/social work on any device; the Clip Finder camera and AR mapping
flows check `ARWorldTrackingConfiguration.isSupported` and explain themselves
on unsupported hardware. This also means the app runs in the Simulator for
everything except the camera/AR screens.

## Build setup (one time, on a Mac)

1. **Generate the Xcode project** (the `.xcodeproj` is generated, not
   checked in — `project.yml` is the source of truth, playing the role
   `build.gradle.kts` does on Android):

   ```bash
   brew install xcodegen
   cd RocklenseAB-iOS
   xcodegen generate
   open RocklenseAB.xcodeproj
   ```

2. **Firebase**: in the [Firebase console](https://console.firebase.google.com),
   open the SAME project the Android app uses → Project settings → *Add app*
   → iOS. Bundle ID: `com.rocklense.ab`. Download **GoogleService-Info.plist**
   and drop it into the `RocklenseAB/` folder in Xcode (add to the app
   target). Re-run `xcodegen generate` if you place it on disk first.

3. **Google Sign-In URL scheme**: open GoogleService-Info.plist, copy the
   `REVERSED_CLIENT_ID` value, then in Xcode → target → Info → URL Types →
   add a URL scheme with that value. (This is the step Google sign-in
   silently fails without.)

4. **Sign in with Apple**:
   - Xcode → target → Signing & Capabilities → *+ Capability* → Sign in with
     Apple (requires a paid Apple Developer account team).
   - Firebase console → Authentication → Sign-in method → enable **Apple**.
   (Google should already be enabled from the Android app.)

5. **Bundled sample wall image**: the Echo Canyon demo wall references
   `echo_canyon_rusty_wall.jpg`. Copy the Android app's
   `assets/ar_images/` folder into the project and add it to Xcode as a
   **folder reference** (blue folder, "Create folder references" in the add
   dialog) named `ar_images` — the code loads it via
   `Bundle.main.url(..., subdirectory: "ar_images")`, which only works with
   a real folder reference, not a yellow group.

6. Build & run on a physical iPhone for anything AR (Simulator has no
   camera/ARKit).

No Firestore rule changes, no new indexes: every query keeps to single
where-clauses with client-side sorting/filtering, exactly like the Android
client, so `firestore.rules`/`storage.rules` stay as they are.

## Field-verify the AR clip positions (do this once)

`AR/ARWallMath.swift` is a **verbatim formula-for-formula port** of the
Android renderers' coordinate math: it renders a stored clip at anchor-local
`(x − halfWidth, 0, y − halfHeight)` and stores a tapped point as
`(local.x + halfWidth, local.z + halfHeight)` — the exact same expressions
as `ArGlRenderer` and `PlaceStartClipRenderer`. Since ARKit's ARImageAnchor
and ARCore's AugmentedImage define the same local frame for a tracked image
(center origin, X across the image, Y as the surface normal, Z along the
image vertically), matching the formulas verbatim is what guarantees a clip
placed on either platform lands at the same physical spot on both.

**The check** (a confirmation, not a bug hunt): stand an Android phone and
an iPhone side by side pointed at the same phone-mapped wall — clip markers
must appear in the same positions on both. If they ever don't, the two
functions in `ARWallMath.swift` are the single source of truth for the
mapping; nothing else needs touching.

## App Store submission notes

- **Guideline 4.8** — third-party login: satisfied (Sign in with Apple is
  offered alongside Google).
- **Guideline 5.1.1(v)** — account deletion: satisfied (Settings → Delete
  profile performs a full cascade: reviews, friendships, avatar, profile
  doc, and the Auth account itself).
- **Privacy nutrition labels**: declare Location (coarse use: nearby-crag
  sorting), Photos (user-selected only, via PhotosPicker — no library
  permission is requested), Camera, User Content (photos, reviews), and
  Identifiers/Contact Info per your Firebase Auth setup.
- **Age rating**: the setup wizard blocks under-13 signups (same
  reasonable-effort COPPA gate as Android).
- **Ads/tracking**: none, so no ATT prompt needed.

## Project layout

```
project.yml                  XcodeGen spec (targets, SPM deps, Info.plist)
RocklenseAB/
  App/          Entry point, root routing, tab shell
  Theme/        Color/spacing tokens (hex-identical to colors.xml)
  Models/       Codable models — field names match Firestore exactly
  Services/     Auth, CragRepository, FriendsRepository, LocalProfileStore
  AR/           ARWallMath + the three AR screens (Clip Finder, Measure,
                Place Clip) on ARKit/RealityKit
  Features/     One folder per tab: Auth, ClipFinder, Map, Profile
  Resources/    Asset catalog (drop a 1024×1024 app icon into
                AppIcon.appiconset)
```

## Known gaps vs Android (deliberate or pending)

- The first-run tutorial still doesn't exist on either platform; the wizard
  records the preference, same as Android.
- Minimum iOS is **17.0** — the map screen uses SwiftUI MapKit's
  `MapCameraPosition`/`MapReader` APIs (iOS 17+). Supporting iOS 16 would
  mean rewriting that one screen on a wrapped MKMapView; everything else in
  the app is iOS 16-compatible.
- Crashlytics is linked but the dSYM upload build phase isn't scripted in
  project.yml; add Firebase's run-script phase before shipping if you want
  symbolicated crash reports.
