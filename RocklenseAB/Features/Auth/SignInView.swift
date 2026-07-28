import AuthenticationServices
import CoreLocation
import PhotosUI
import SwiftUI

/// The app's entry screen: Sign in with Apple, Google, or "Continue without
/// an account" for an independent (anonymous) profile -- either way lands as
/// a normal signed-in session. Port of SignInFragment with Sign in with
/// Apple added (App Store Guideline 4.8 requires it alongside Google).
struct SignInView: View {
    @EnvironmentObject var auth: AuthService
    let onSignedIn: () -> Void

    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        ZStack {
            RLColor.dusk.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "mountain.2.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(RLColor.rust)
                Text("Rocklense AB")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(RLColor.chalk)
                Text("Find your clips. Map your crags.")
                    .font(.system(size: 15))
                    .foregroundStyle(RLColor.cream70)

                Spacer()

                if let errorText {
                    Text(errorText)
                        .font(.system(size: 13))
                        .foregroundStyle(RLColor.rust)
                        .multilineTextAlignment(.center)
                }

                if loading {
                    ProgressView().tint(RLColor.chalk)
                } else {
                    VStack(spacing: 12) {
                        SignInWithAppleButton(.signIn) { request in
                            let prepared = auth.makeAppleSignInRequest()
                            request.requestedScopes = prepared.requestedScopes
                            request.nonce = prepared.nonce
                        } onCompletion: { result in
                            handleApple(result)
                        }
                        .signInWithAppleButtonStyle(.white)
                        .frame(height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                        Button {
                            signInGoogle()
                        } label: {
                            HStack {
                                Image(systemName: "g.circle.fill")
                                Text("Sign in with Google")
                            }
                        }
                        .buttonStyle(RLPrimaryButtonStyle(background: RLColor.chalk, foreground: RLColor.ink))

                        Button("Continue without an account") {
                            signInAnonymously()
                        }
                        .font(.system(size: 14))
                        .foregroundStyle(RLColor.cream70)
                        .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorText = "Apple sign-in failed \u{2014} try again"; return
            }
            loading = true
            Task {
                do {
                    try await auth.signInWithApple(credential: credential)
                    onSignedIn()
                } catch {
                    errorText = error.localizedDescription
                }
                loading = false
            }
        case .failure(let error):
            // User-cancelled isn't an error worth surfacing.
            if (error as? ASAuthorizationError)?.code != .canceled {
                errorText = error.localizedDescription
            }
        }
    }

    private func signInGoogle() {
        guard let rootVC = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return }
        loading = true
        errorText = nil
        Task {
            do {
                try await auth.signInWithGoogle(presenting: rootVC)
                onSignedIn()
            } catch {
                errorText = error.localizedDescription
            }
            loading = false
        }
    }

    private func signInAnonymously() {
        loading = true
        errorText = nil
        Task {
            do {
                try await auth.signInAnonymously()
                onSignedIn()
            } catch {
                errorText = "Couldn't start a profile \u{2014} try again"
            }
            loading = false
        }
    }
}

// MARK: - Setup wizard (SetupProfileFragment port)

/// Shown once, right after a climber's first sign-in. A short wizard: name,
/// age, climber type, location, an optional photo + bio, then a yes/no
/// tutorial prompt (records the preference; the tutorial itself isn't built
/// yet, matching Android).
struct SetupProfileView: View {
    let onFinished: () -> Void

    @State private var step = 0
    private let totalSteps = 6

    @State private var name = ""
    @State private var ageText = ""
    @State private var locationText = ""
    @State private var bioText = ""
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarImage: UIImage?
    @State private var underageBlocked = false
    @StateObject private var locationFetcher = LocationFetcher()

    var body: some View {
        ZStack {
            RLColor.limestone.ignoresSafeArea()
            VStack(spacing: 24) {
                Text("STEP \(step + 1) OF \(totalSteps)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(RLColor.pine)
                    .padding(.top, 24)

                Spacer()
                stepContent
                Spacer()

                // Steps 2 (climber type) and 5 (tutorial) advance via their
                // own buttons, not the generic Next/Back row.
                if step != 2 && step != 5 {
                    HStack {
                        Button("Back") { step = max(0, step - 1) }
                            .opacity(step == 0 ? 0 : 1)
                        Spacer()
                        Button(step == 4 ? "Continue" : "Next") { advance() }
                            .buttonStyle(RLPrimaryButtonStyle())
                            .frame(width: 160)
                    }
                    .padding(.horizontal, RLMetrics.screenPadding)
                    .padding(.bottom, 24)
                }
            }
        }
        .alert("Sorry, this app isn't available for users under 13", isPresented: $underageBlocked) {
            Button("OK", role: .cancel) {}
        }
        .onChange(of: avatarItem) { item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    avatarImage = image
                }
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0:
            wizardField(title: "What's your name?", text: $name, placeholder: "Name")
        case 1:
            wizardField(title: "How old are you?", text: $ageText, placeholder: "Age", keyboard: .numberPad)
        case 2:
            VStack(spacing: 16) {
                Text("What kind of climber are you?")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(RLColor.ink)
                Button("Sport") { chooseType("Sport") }
                    .buttonStyle(RLPrimaryButtonStyle())
                Button("Trad") { chooseType("Trad") }
                    .buttonStyle(RLPrimaryButtonStyle(background: RLColor.pine))
            }
            .padding(.horizontal, 40)
        case 3:
            VStack(spacing: 16) {
                wizardField(title: "Where are you based?", text: $locationText, placeholder: "City, Region")
                Button {
                    locationFetcher.fetch { label in
                        if let label { locationText = label }
                    }
                } label: {
                    Label("Use my current location", systemImage: "location.fill")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
        case 4:
            VStack(spacing: 16) {
                Text("Add a photo and a short bio")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(RLColor.ink)
                PhotosPicker(selection: $avatarItem, matching: .images) {
                    Group {
                        if let avatarImage {
                            Image(uiImage: avatarImage).resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.system(size: 44))
                                .foregroundStyle(RLColor.pine)
                        }
                    }
                    .frame(width: 110, height: 110)
                    .background(RLColor.chalk)
                    .clipShape(Circle())
                }
                TextField("A little about your climbing...", text: $bioText, axis: .vertical)
                    .lineLimit(3...5)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 40)
            }
        default:
            VStack(spacing: 16) {
                Text("Want a quick tutorial\nwhen it's ready?")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(RLColor.ink)
                    .multilineTextAlignment(.center)
                Button("Yes please") { finish(wantsTutorial: true) }
                    .buttonStyle(RLPrimaryButtonStyle())
                Button("No thanks") { finish(wantsTutorial: false) }
                    .buttonStyle(RLPrimaryButtonStyle(background: RLColor.pine))
            }
            .padding(.horizontal, 40)
        }
    }

    private func wizardField(title: String, text: Binding<String>, placeholder: String,
                              keyboard: UIKeyboardType = .default) -> some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(RLColor.ink)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 40)
        }
    }

    private func advance() {
        switch step {
        case 0: LocalProfileStore.name = name.trimmingCharacters(in: .whitespaces)
        case 1:
            // Basic COPPA compliance gate, same reasonable-effort check as
            // the Android wizard: block under-13 signup rather than silently
            // proceeding (no parental-consent flow exists).
            if let age = Int(ageText.trimmingCharacters(in: .whitespaces)), age < 13 {
                underageBlocked = true
                return
            }
            LocalProfileStore.age = ageText.trimmingCharacters(in: .whitespaces)
        case 3: LocalProfileStore.location = locationText.trimmingCharacters(in: .whitespaces)
        case 4: LocalProfileStore.bio = bioText.trimmingCharacters(in: .whitespaces)
        default: break
        }
        step = min(totalSteps - 1, step + 1)
    }

    private func chooseType(_ type: String) {
        LocalProfileStore.climberType = type
        step += 1
    }

    private func finish(wantsTutorial: Bool) {
        LocalProfileStore.wantsTutorial = wantsTutorial
        LocalProfileStore.hasCompletedProfileSetup = true
        FriendsRepository.shared.markSetupComplete()
        FriendsRepository.shared.syncCurrentUserProfile()

        if let avatarImage {
            AvatarStore.saveLocal(avatarImage)
            FriendsRepository.shared.uploadAvatar(avatarImage) { _ in }
        }
        onFinished()
    }
}

// MARK: - Location helper (fetch + reverse geocode, port of the wizard's fetchCurrentLocation)

final class LocationFetcher: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var labelCompletion: ((String?) -> Void)?
    private var coordinateCompletion: ((CLLocationCoordinate2D?) -> Void)?
    private let geocoder = CLGeocoder()

    /// Fetch and reverse-geocode into a readable "City, Region" label,
    /// falling back to raw coordinates -- the wizard's location step.
    func fetch(completion: @escaping (String?) -> Void) {
        labelCompletion = completion
        startFetch()
    }

    /// Fetch raw coordinates -- used by AddCragSheet's "use current
    /// location" pre-fill.
    func fetchCoordinates(completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        coordinateCompletion = completion
        startFetch()
    }

    private func startFetch() {
        manager.delegate = self
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        default:
            labelCompletion?(nil); labelCompletion = nil
            coordinateCompletion?(nil); coordinateCompletion = nil
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else {
            labelCompletion?(nil); labelCompletion = nil
            coordinateCompletion?(nil); coordinateCompletion = nil
            return
        }
        coordinateCompletion?(location.coordinate)
        coordinateCompletion = nil

        if let labelCompletion {
            geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                let p = placemarks?.first
                let label = [p?.locality, p?.administrativeArea].compactMap { $0 }.joined(separator: ", ")
                labelCompletion(label.isEmpty
                                ? String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude)
                                : label)
            }
            self.labelCompletion = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        labelCompletion?(nil); labelCompletion = nil
        coordinateCompletion?(nil); coordinateCompletion = nil
    }
}

/// Local avatar file storage, scoped per signed-in account (mirrors the
/// Android profile_avatar_{uid}.jpg pattern).
@MainActor
enum AvatarStore {
    static var localURL: URL {
        let uid = AuthService.shared.currentUser?.uid ?? "guest"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("profile_avatar_\(uid).jpg")
    }
    static func saveLocal(_ image: UIImage) {
        if let data = image.jpegData(compressionQuality: 0.9) {
            try? data.write(to: localURL)
        }
    }
    static func loadLocal() -> UIImage? {
        UIImage(contentsOfFile: localURL.path)
    }
}
