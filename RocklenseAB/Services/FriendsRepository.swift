import FirebaseFirestore
import FirebaseStorage
import UIKit

/// Search-for-friends, friend requests, friendships, and the public side of a
/// climber's profile (what's visible to OTHER users -- see UserProfile).
/// Every query here intentionally uses only a SINGLE Firestore where-clause
/// (or none), filtering anything else client-side -- combining a whereEqualTo
/// with a different field's whereEqualTo/orderBy requires a manual composite
/// index in Firestore, and a query missing that index just fails outright.
/// Keeping to automatic single-field indexes (same decision as the Android
/// app, for the same reason) means NO new Firestore indexes are needed for
/// the iOS client -- it runs against the exact same backend as-is.
@MainActor
final class FriendsRepository {
    static let shared = FriendsRepository()
    private let db = Firestore.firestore()
    private let storage = Storage.storage()
    private init() {}

    /// Call once after any successful sign-in, and again whenever the climber
    /// saves changes on Edit Profile -- writes/updates this user's PUBLIC
    /// profile so friends can actually see it. Uses merge, not overwrite,
    /// so fields like hasCompletedSetup on the same doc aren't wiped.
    func syncCurrentUserProfile() {
        guard let user = AuthService.shared.currentUser else { return }
        let name = LocalProfileStore.name.isEmpty
            ? (user.displayName ?? user.email?.components(separatedBy: "@").first ?? "Climber")
            : LocalProfileStore.name
        let profile: [String: Any] = [
            "uid": user.uid,
            "displayName": name,
            "displayNameLower": name.lowercased(),
            "email": user.email ?? "",
            "location": LocalProfileStore.location,
            "bio": LocalProfileStore.bio,
            "climberType": LocalProfileStore.climberType
        ]
        db.collection("users").document(user.uid).setData(profile, merge: true)
    }

    /// Uploads the avatar to Storage and records its download URL on the
    /// user's public profile doc -- what makes the photo visible to friends,
    /// not just this device. Path matches storage.rules: avatars/{uid}.jpg.
    func uploadAvatar(_ image: UIImage, completion: @escaping (Bool) -> Void) {
        guard let uid = AuthService.shared.currentUser?.uid,
              let data = image.jpegData(compressionQuality: 0.85) else { completion(false); return }
        let ref = storage.reference().child("avatars/\(uid).jpg")
        ref.putData(data) { [weak self] _, error in
            guard let self, error == nil else { completion(false); return }
            ref.downloadURL { url, error in
                guard let url, error == nil else { completion(false); return }
                self.db.collection("users").document(uid)
                    .setData(["avatarUrl": url.absoluteString], merge: true) { error in
                        completion(error == nil)
                    }
            }
        }
    }

    /// Fetches another climber's public profile -- only what
    /// syncCurrentUserProfile/uploadAvatar write; nothing private.
    func fetchUserProfile(uid: String, completion: @escaping (UserProfile?) -> Void) {
        db.collection("users").document(uid).getDocument { doc, _ in
            completion(doc.flatMap { try? $0.data(as: UserProfile.self) })
        }
    }

    /// Whether THIS ACCOUNT (not just this device) has already been through
    /// the post-sign-in profile setup wizard -- stored on the account's own
    /// Firestore doc so a previously-registered account on a new device
    /// doesn't see onboarding again. Falls back to the local flag if the
    /// read fails (e.g. offline).
    func checkSetupComplete(completion: @escaping (Bool) -> Void) {
        guard let uid = AuthService.shared.currentUser?.uid else { completion(false); return }
        db.collection("users").document(uid).getDocument { doc, error in
            Task { @MainActor in
                if error != nil {
                    completion(LocalProfileStore.hasCompletedProfileSetup)
                    return
                }
                let remote = doc?.get("hasCompletedSetup") as? Bool
                completion(remote ?? LocalProfileStore.hasCompletedProfileSetup)
            }
        }
    }

    /// Call once the setup wizard finishes -- marks completion on the
    /// account itself, not just this device.
    func markSetupComplete() {
        guard let uid = AuthService.shared.currentUser?.uid else { return }
        db.collection("users").document(uid).setData(["hasCompletedSetup": true], merge: true)
    }

    /// Deletes EVERYTHING tied to this account across Firestore and Storage:
    /// public profile doc, every friend request/friendship row, every review
    /// this account posted, and the avatar file -- called as part of account
    /// deletion (AuthService.deleteAccount handles the Firebase Auth account
    /// removal itself). Same "delete it all so the confirmation copy is
    /// accurate" scope as the Android version.
    func deleteCurrentUserSocialData(completion: @escaping (Bool) -> Void) {
        guard let uid = AuthService.shared.currentUser?.uid else { completion(false); return }

        db.collection("reviews").whereField("authorUid", isEqualTo: uid).getDocuments { [weak self] reviewSnap, error in
            guard let self, error == nil else { completion(false); return }
            reviewSnap?.documents.forEach { $0.reference.delete() }

            // Completes either way -- a missing avatar file throwing "object
            // does not exist" isn't a real failure worth blocking deletion over.
            self.storage.reference().child("avatars/\(uid).jpg").delete { _ in
                self.db.collection("users").document(uid).delete { error in
                    guard error == nil else { completion(false); return }
                    self.db.collection("friendRequests").whereField("fromUid", isEqualTo: uid).getDocuments { fromSnap, _ in
                        fromSnap?.documents.forEach { $0.reference.delete() }
                        self.db.collection("friendRequests").whereField("toUid", isEqualTo: uid).getDocuments { toSnap, _ in
                            toSnap?.documents.forEach { $0.reference.delete() }
                            completion(true)
                        }
                    }
                }
            }
        }
    }

    /// Prefix search on lowercased display name (Firestore's standard
    /// startAt/endAt "starts with" workaround).
    func searchUsers(query: String, completion: @escaping ([UserProfile]) -> Void) {
        let myUid = AuthService.shared.currentUser?.uid
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { completion([]); return }
        db.collection("users")
            .order(by: "displayNameLower")
            .start(at: [q])
            .end(at: [q + "\u{f8ff}"])
            .limit(to: 20)
            .getDocuments { snapshot, _ in
                let results = snapshot?.documents.compactMap { try? $0.data(as: UserProfile.self) }
                    .filter { $0.uid != myUid } ?? []
                completion(results)
            }
    }

    func sendFriendRequest(toUid: String, toName: String, completion: @escaping (Bool) -> Void) {
        guard let me = AuthService.shared.currentUser else { completion(false); return }
        let myName = LocalProfileStore.name.isEmpty ? (me.displayName ?? "Climber") : LocalProfileStore.name
        let request: [String: Any] = [
            "fromUid": me.uid, "fromName": myName,
            "toUid": toUid, "toName": toName,
            "status": "pending", "timestampMillis": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        db.collection("friendRequests").addDocument(data: request) { error in completion(error == nil) }
    }

    /// Requests sent TO the current user that haven't been responded to yet.
    func incomingPendingRequests(completion: @escaping ([FriendRequest]) -> Void) {
        guard let myUid = AuthService.shared.currentUser?.uid else { completion([]); return }
        db.collection("friendRequests").whereField("toUid", isEqualTo: myUid).getDocuments { snapshot, _ in
            let requests = snapshot?.documents.compactMap { doc -> FriendRequest? in
                var r = try? doc.data(as: FriendRequest.self)
                r?.id = doc.documentID
                return r
            }.filter { $0.status == "pending" } ?? []
            completion(requests)
        }
    }

    /// Accepted friendships involving the current user, in either direction
    /// -- fetches every accepted request and filters client-side rather than
    /// an OR query, fine at this app's current scale (same as Android).
    func friendsList(completion: @escaping ([FriendRequest]) -> Void) {
        guard let myUid = AuthService.shared.currentUser?.uid else { completion([]); return }
        db.collection("friendRequests").whereField("status", isEqualTo: "accepted").getDocuments { snapshot, _ in
            let mine = snapshot?.documents.compactMap { doc -> FriendRequest? in
                var r = try? doc.data(as: FriendRequest.self)
                r?.id = doc.documentID
                return r
            }.filter { $0.fromUid == myUid || $0.toUid == myUid } ?? []
            completion(mine)
        }
    }

    func respondToRequest(requestId: String, accept: Bool, completion: @escaping (Bool) -> Void) {
        if accept {
            db.collection("friendRequests").document(requestId)
                .updateData(["status": "accepted"]) { error in completion(error == nil) }
        } else {
            db.collection("friendRequests").document(requestId).delete { error in completion(error == nil) }
        }
    }

    /// Removes an accepted friendship (from either direction) by the OTHER
    /// person's uid.
    func removeFriend(otherUid: String, completion: @escaping (Bool) -> Void) {
        guard let myUid = AuthService.shared.currentUser?.uid else { completion(false); return }
        db.collection("friendRequests").whereField("status", isEqualTo: "accepted").getDocuments { snapshot, _ in
            let match = snapshot?.documents.first { doc in
                let from = doc.get("fromUid") as? String
                let to = doc.get("toUid") as? String
                return (from == myUid && to == otherUid) || (from == otherUid && to == myUid)
            }
            guard let match else { completion(false); return }
            match.reference.delete { error in completion(error == nil) }
        }
    }
}

/// Reports are write-only from the app's perspective (see firestore.rules) --
/// nobody can read them back through the app. Reviewing reports happens in
/// the Firebase console. (Port of ModerationRepository.kt.)
@MainActor
final class ModerationRepository {
    static let shared = ModerationRepository()
    private let db = Firestore.firestore()
    private init() {}

    func reportReview(_ review: Review, completion: @escaping (Bool) -> Void) {
        guard let reporterUid = AuthService.shared.currentUser?.uid else { completion(false); return }
        let report: [String: Any] = [
            "type": "review",
            "reviewId": review.id,
            "reviewCragId": review.cragId,
            "reviewAuthorUid": review.authorUid,
            "reviewText": review.text,
            "reporterUid": reporterUid,
            "timestampMillis": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        db.collection("reports").addDocument(data: report) { error in completion(error == nil) }
    }
}
