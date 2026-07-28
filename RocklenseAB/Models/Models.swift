import Foundation

// MARK: - Crag / Wall / Route / ClipPoint
//
// Ported field-for-field from the Android app's Models.kt. Firestore field
// names are preserved exactly (CodingKeys mirror the Kotlin @PropertyName
// annotations) so this reads/writes the SAME documents the Android app does
// -- both platforms share one Firestore project, live.

/// A single bolt/clip position on a route, expressed as an offset in METRES
/// from the wall's reference anchor image. x = right, y = up, measured on the
/// wall's face plane, from its bottom-left corner. These offsets are what let
/// us place AR markers once ARKit has localized the reference image in 3D
/// space (see ARClipFinderView).
struct ClipPoint: Codable, Equatable, Hashable {
    var xOffsetMeters: Float = 0
    var yOffsetMeters: Float = 0
}

struct Route: Codable, Identifiable, Equatable, Hashable {
    var id: String = ""
    var name: String = ""
    var grade: String = ""          // YDS, e.g. "5.10a"
    var lengthMeters: Int = 0
    var boltCount: Int = 0
    var clips: [ClipPoint] = []     // first entry = first clip
}

/// A single physical rock face at a crag. Each wall has its own AR reference
/// photo(s) and its own list of routes climbed on that wall.
struct Wall: Codable, Identifiable, Equatable, Hashable {
    var id: String = ""
    var name: String = ""
    var routes: [Route] = []

    /// Filename in the app bundle's `ar_images/` folder used as the ARKit
    /// detection-image target for this wall. Only set for the bundled sample
    /// wall -- nil for walls created from the phone.
    var referenceImageAsset: String?

    /// Download URLs of reference photos captured in-app and uploaded to
    /// Firebase Storage. Every photo in this list must frame the SAME
    /// physical rectangle of wall as the first one -- that's what lets ARKit
    /// recognize any one of them and still place markers correctly using the
    /// single shared referenceImageWidthMeters/HeightMeters below.
    var referenceImageUrls: [String] = []

    /// Physical width/height in metres of the reference image(s) above,
    /// required by ARKit to scale tracking correctly, and needed to convert
    /// ARKit's center-anchored image pose into bottom-left-corner-relative
    /// coordinates (see ClipPoint).
    var referenceImageWidthMeters: Float = 1
    var referenceImageHeightMeters: Float = 1

    /// Fractional (0..1) positions of 3-4 distinctive real-world features the
    /// climber tapped on the first reference photo during setup. Saved so the
    /// Clip Finder camera can draw them as FIXED on-screen guide brackets
    /// every time -- training the climber to physically re-stand at roughly
    /// the same position/angle the wall was originally mapped from.
    var alignmentMarkerXFractions: [Float] = []
    var alignmentMarkerYFractions: [Float] = []

    /// An OPTIONAL second, independent reference bar -- see the note on the
    /// Android model. Empty when not set.
    var alignmentMarker2XFractions: [Float] = []
    var alignmentMarker2YFractions: [Float] = []

    var isMapped: Bool { referenceImageAsset != nil || !referenceImageUrls.isEmpty }
}

struct Crag: Codable, Identifiable, Equatable, Hashable {
    var id: String = ""
    var name: String = ""
    var area: String = ""
    var lat: Double = 0
    var lng: Double = 0
    var blurb: String = ""
    var tags: [String] = []
    var walls: [Wall] = []

    /// Decorative photos of the crag itself (NOT AR wall reference images).
    /// First one is the primary/hero photo.
    var photoUrls: [String] = []

    var routeCount: Int { walls.reduce(0) { $0 + $1.routes.count } }
}

struct Review: Codable, Identifiable, Equatable, Hashable {
    var id: String = ""
    var cragId: String = ""
    var author: String = ""
    /// Must match the poster's own uid at creation time -- enforced by
    /// firestore.rules for edit/delete. Same rules file as Android; unchanged.
    var authorUid: String = ""
    var stars: Int = 0
    var text: String = ""
    var timestampMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
}

// MARK: - Social models (SocialModels.kt)

/// A minimal public profile stored per-account so other climbers can find and
/// add each other -- separate from LocalProfileStore, which is private and
/// device-only.
struct UserProfile: Codable, Equatable, Hashable {
    var uid: String = ""
    var displayName: String = ""
    /// Lowercased copy of displayName, used for Firestore's startAt/endAt
    /// prefix-search technique (Firestore has no native "contains" search).
    var displayNameLower: String = ""
    var email: String = ""
    var location: String = ""
    var bio: String = ""
    var climberType: String = ""
    /// Firebase Storage download URL -- visible to other climbers, unlike
    /// the local avatar file.
    var avatarUrl: String = ""
}

/// One row per friend request -- "pending" until the recipient responds,
/// then either "accepted" or deleted (declined).
struct FriendRequest: Codable, Identifiable, Equatable, Hashable {
    var id: String = ""
    var fromUid: String = ""
    var fromName: String = ""
    var toUid: String = ""
    var toName: String = ""
    var status: String = "pending" // "pending" | "accepted"
    var timestampMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
}

// MARK: - Client-only helper types (ClimbListItem.kt / CragUtils.kt)

/// A single route flattened together with its wall/crag context and distance
/// from the climber -- for the "Climbs Near You" map sheet.
struct ClimbListItem: Identifiable, Equatable, Hashable {
    var id: String { route.id + "@" + wall.id }
    let route: Route
    let wall: Wall
    let crag: Crag
    let distanceKm: Float?
}

func buildClimbList(crags: [Crag], distancesKm: [String: Float]) -> [ClimbListItem] {
    let items = crags.flatMap { crag in
        crag.walls.flatMap { wall in
            wall.routes.map { route in
                ClimbListItem(route: route, wall: wall, crag: crag, distanceKm: distancesKm[crag.id])
            }
        }
    }
    return items.sorted { ($0.distanceKm ?? .greatestFiniteMagnitude) < ($1.distanceKm ?? .greatestFiniteMagnitude) }
}

/// Extracts the numeric part of a YDS grade (e.g. 10 from "5.10a") for
/// comparisons/filtering -- ignores the a/b/c/d suffix.
func parseGradeNumeric(_ grade: String) -> Int? {
    guard let range = grade.range(of: #"5\.(\d+)"#, options: .regularExpression) else { return nil }
    let match = String(grade[range])
    let digits = match.drop(while: { $0 != "." }).dropFirst()
    return Int(digits)
}

/// Best-effort grade range across every route at a crag, e.g. "5.6\u20135.11".
func gradeRangeLabel(_ crag: Crag?) -> String {
    let grades = crag?.walls.flatMap { $0.routes }.map { $0.grade } ?? []
    if grades.isEmpty { return "No routes" }
    let numeric = grades.compactMap(parseGradeNumeric)
    guard let min = numeric.min(), let max = numeric.max() else { return grades[0] }
    return min == max ? "5.\(min)" : "5.\(min)\u{2013}5.\(max)"
}
