import FirebaseCore
import GoogleSignIn
import SwiftUI

@main
struct RocklenseABApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var auth = AuthService.shared
    @StateObject private var cragRepo = CragRepository.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(cragRepo)
                .tint(RLColor.rust)
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        FirebaseApp.configure()
        // Starts the live Firestore listener that keeps CragRepository.crags
        // in sync -- same single startup call as MainActivity.onCreate.
        Task { @MainActor in CragRepository.shared.startListening() }
        return true
    }
}

/// Routing shell: sign-in -> (first-time only) profile setup wizard -> the
/// three-tab app. Mirrors SignInFragment's navigateToApp logic, including
/// checking setup completion against the ACCOUNT's Firestore record (not
/// just this device's local flag) so a returning account on a new device
/// doesn't see onboarding again.
struct RootView: View {
    @EnvironmentObject var auth: AuthService

    private enum Phase { case signIn, checkingSetup, setupWizard, tutorial, main }
    @State private var phase: Phase = .signIn

    var body: some View {
        Group {
            switch phase {
            case .signIn:
                SignInView(onSignedIn: routeAfterSignIn, onSkip: routeToTutorial)
            case .checkingSetup:
                ZStack { RLColor.limestone.ignoresSafeArea(); ProgressView() }
            case .setupWizard:
                SetupProfileView(onFinished: { phase = .main })
            case .tutorial:
                TutorialView(onFinished: { phase = .main })
            case .main:
                MainTabView()
            }
        }
        .onAppear {
            // Already signed in from a previous launch -- skip the sign-in UI.
            if auth.isSignedIn && phase == .signIn { routeAfterSignIn() }
        }
        .onChange(of: auth.isSignedIn) { signedIn in
            if !signedIn { phase = .signIn }
        }
    }

    private func routeAfterSignIn() {
        phase = .checkingSetup
        FriendsRepository.shared.syncCurrentUserProfile()
        FriendsRepository.shared.checkSetupComplete { completed in
            phase = completed ? .main : .setupWizard
        }
    }

    /// Skip button's destination -- bypasses the name/age/location wizard
    /// entirely and goes straight to the short tutorial, landing in the app
    /// with an empty-but-functional profile the climber can fill in later
    /// from Edit Profile.
    private func routeToTutorial() {
        LocalProfileStore.hasCompletedProfileSetup = true
        FriendsRepository.shared.markSetupComplete()
        FriendsRepository.shared.syncCurrentUserProfile()
        phase = .tutorial
    }
}

/// The three tabs: Clip Finder / Crag Map / Profile -- same order and names
/// as bottom_nav_menu.xml.
struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack { SelectClimbView() }
                .tabItem { Label("Clip Finder", systemImage: "camera.viewfinder") }

            NavigationStack { CragMapView() }
                .tabItem { Label("Crag Map", systemImage: "map") }

            NavigationStack { ProfileView() }
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
    }
}
