import Foundation

/// Everything here lives on THIS device only, via UserDefaults -- not synced
/// across devices. Scoped to whichever account is currently signed in, via a
/// key prefix per uid (the iOS equivalent of Android's separate
/// SharedPreferences file per uid), so switching accounts shows that
/// account's own data instead of one shared pile for the whole device.
@MainActor
enum LocalProfileStore {

    private static var uidPrefix: String {
        "profile_\(AuthService.shared.currentUser?.uid ?? "guest")_"
    }
    private static var defaults: UserDefaults { .standard }

    static var name: String {
        get { defaults.string(forKey: uidPrefix + "name") ?? "" }
        set { defaults.set(newValue, forKey: uidPrefix + "name") }
    }
    static var location: String {
        get { defaults.string(forKey: uidPrefix + "location") ?? "" }
        set { defaults.set(newValue, forKey: uidPrefix + "location") }
    }
    static var bio: String {
        get { defaults.string(forKey: uidPrefix + "bio") ?? "" }
        set { defaults.set(newValue, forKey: uidPrefix + "bio") }
    }
    static var age: String {
        get { defaults.string(forKey: uidPrefix + "age") ?? "" }
        set { defaults.set(newValue, forKey: uidPrefix + "age") }
    }
    /// "Sport" or "Trad" -- set during the post-sign-in setup wizard.
    static var climberType: String {
        get { defaults.string(forKey: uidPrefix + "climberType") ?? "" }
        set { defaults.set(newValue, forKey: uidPrefix + "climberType") }
    }
    static var hasCompletedProfileSetup: Bool {
        get { defaults.bool(forKey: uidPrefix + "hasCompletedProfileSetup") }
        set { defaults.set(newValue, forKey: uidPrefix + "hasCompletedProfileSetup") }
    }
    static var wantsTutorial: Bool {
        get { defaults.object(forKey: uidPrefix + "wantsTutorial") as? Bool ?? true }
        set { defaults.set(newValue, forKey: uidPrefix + "wantsTutorial") }
    }

    struct RecentClimb: Codable {
        let cragId: String
        let wallId: String
        let routeId: String
        let timestampMillis: Int64
    }

    static func recentClimbs() -> [RecentClimb] {
        guard let data = defaults.data(forKey: uidPrefix + "recentClimbs"),
              let list = try? JSONDecoder().decode([RecentClimb].self, from: data) else { return [] }
        return list
    }

    /// Called automatically whenever the Clip Finder camera recognizes a wall
    /// and successfully tracks a route on it. Most-recent-first, capped at 20;
    /// re-scanning a route already in the list moves it back to the front.
    static func recordRecentClimb(cragId: String, wallId: String, routeId: String) {
        var updated = recentClimbs().filter { $0.routeId != routeId }
        updated.insert(RecentClimb(cragId: cragId, wallId: wallId, routeId: routeId,
                                    timestampMillis: Int64(Date().timeIntervalSince1970 * 1000)), at: 0)
        let capped = Array(updated.prefix(20))
        if let data = try? JSONEncoder().encode(capped) {
            defaults.set(data, forKey: uidPrefix + "recentClimbs")
        }
    }

    static func clearRecentClimbs() {
        defaults.removeObject(forKey: uidPrefix + "recentClimbs")
    }

    static func favoriteRouteIds() -> Set<String> {
        Set(defaults.stringArray(forKey: uidPrefix + "favoriteRouteIds") ?? [])
    }

    static func isFavorite(_ routeId: String) -> Bool { favoriteRouteIds().contains(routeId) }

    static func toggleFavorite(_ routeId: String) {
        var updated = favoriteRouteIds()
        if updated.contains(routeId) {
            updated.remove(routeId)
        } else {
            updated.insert(routeId)
        }
        defaults.set(Array(updated), forKey: uidPrefix + "favoriteRouteIds")
    }

    /// IDs of reviews posted from this device -- there's no author-account
    /// query path for this yet, so "my reviews" means "reviews I remember posting."
    static func postedReviewIds() -> [String] {
        defaults.stringArray(forKey: uidPrefix + "postedReviewIds") ?? []
    }

    static func recordPostedReview(_ reviewId: String) {
        var updated = postedReviewIds()
        updated.insert(reviewId, at: 0)
        defaults.set(updated, forKey: uidPrefix + "postedReviewIds")
    }
}
