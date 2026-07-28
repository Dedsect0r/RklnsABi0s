import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import Foundation
import GoogleSignIn
import UIKit

/// Wraps Firebase Auth for the whole app. Three ways to get an account, all
/// landing as a normal FirebaseAuth session:
///  - Google Sign-In (signInWithGoogle)
///  - Sign in with Apple (signInWithApple) -- required alongside Google per
///    App Store Review Guideline 4.8 ("sign in with a third-party service"
///    triggers the requirement to also offer Apple's).
///  - An "independent" profile not tied to any account (signInAnonymously)
///    -- Firebase's built-in anonymous auth, matching the Android app's
///    "Continue without Google" option.
///
/// IMPORTANT SETUP STEPS (can't be done from code -- see README_iOS.md):
///  1. Add an iOS app to the SAME Firebase project the Android app uses,
///     download GoogleService-Info.plist, drop it into the RocklenseAB
///     folder before building.
///  2. Firebase Console > Authentication > Sign-in method > enable Google
///     AND Apple.
///  3. Register the URL scheme from GoogleService-Info.plist's
///     REVERSED_CLIENT_ID under Info > URL Types in Xcode (XcodeGen's
///     project.yml doesn't set this since it depends on your specific
///     Firebase project's generated value).
///  4. Xcode > Signing & Capabilities > add "Sign in with Apple" capability.
///
/// Profile data itself (name/location/bio/climberType/recents/favorites)
/// lives in LocalProfileStore (device-only), same split as Android.
@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published private(set) var currentUser: User?
    @Published private(set) var isSignedIn: Bool = false

    /// True if signed in via Google or Apple (has a real provider identity)
    /// as opposed to an independent/anonymous profile.
    var isLinkedAccount: Bool {
        currentUser?.providerData.contains { $0.providerID == GoogleAuthProviderID || $0.providerID == "apple.com" } == true
    }
    var isGoogleAccount: Bool {
        currentUser?.providerData.contains { $0.providerID == GoogleAuthProviderID } == true
    }
    private let GoogleAuthProviderID = "google.com"

    private var authHandle: AuthStateDidChangeListenerHandle?
    private var currentAppleNonce: String?

    private init() {
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            self?.currentUser = user
            self?.isSignedIn = user != nil
        }
    }

    // MARK: Google Sign-In

    func signInWithGoogle(presenting viewController: UIViewController) async throws {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw AuthError.message("Firebase isn't configured -- missing GoogleService-Info.plist")
        }
        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: viewController)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthError.message("Google didn't return an ID token")
        }
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
        _ = try await Auth.auth().signIn(with: credential)
    }

    // MARK: Sign in with Apple

    /// Call this to get the request to hand to an ASAuthorizationController,
    /// then pass the resulting credential to `signInWithApple(credential:)`.
    func makeAppleSignInRequest() -> ASAuthorizationAppleIDRequest {
        let nonce = Self.randomNonceString()
        currentAppleNonce = nonce
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
        return request
    }

    func signInWithApple(credential appleIDCredential: ASAuthorizationAppleIDCredential) async throws {
        guard let nonce = currentAppleNonce else {
            throw AuthError.message("Invalid sign-in state -- try again")
        }
        guard let tokenData = appleIDCredential.identityToken,
              let idTokenString = String(data: tokenData, encoding: .utf8) else {
            throw AuthError.message("Apple didn't return an identity token")
        }
        let credential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: nonce,
            fullName: appleIDCredential.fullName
        )
        _ = try await Auth.auth().signIn(with: credential)
    }

    // MARK: Anonymous ("independent profile")

    func signInAnonymously() async throws {
        _ = try await Auth.auth().signInAnonymously()
    }

    // MARK: Sign out / delete

    func signOut() throws {
        GIDSignIn.sharedInstance.signOut()
        try Auth.auth().signOut()
    }

    /// Deletes the Firebase Auth account itself -- irreversible. Firebase
    /// requires a RECENT sign-in for this; if it's been a while this throws
    /// and the caller should prompt to sign out/in again, matching Android's
    /// needsReauth handling.
    func deleteAccount() async throws {
        guard let user = currentUser else { throw AuthError.message("Not signed in") }
        try await user.delete()
    }

    enum AuthError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let m): return m }
        }
    }

    // MARK: Apple nonce helpers (Apple's documented pattern for Firebase + Sign in with Apple)

    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if status != errSecSuccess {
            fatalError("Unable to generate nonce.")
        }
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256(_ input: String) -> String {
        let hashed = SHA256.hash(data: Data(input.utf8))
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}
