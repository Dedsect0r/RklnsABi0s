import FirebaseFirestore
import FirebaseStorage
import UIKit

/// Firestore-backed store for the Crag -> Wall -> Route hierarchy. Each crag
/// is one document in a top-level "crags" collection, with its walls (and
/// each wall's routes) embedded as nested array fields on that document --
/// same shape the Android app writes, so both platforms read/write the exact
/// same documents live.
///
/// Published `crags` is kept in sync via a live Firestore listener -- SwiftUI
/// views observe this object directly (`@EnvironmentObject` / `@ObservedObject`)
/// rather than polling, the natural Swift equivalent of Android's
/// CragRepository.observe() callback list.
@MainActor
final class CragRepository: ObservableObject {
    static let shared = CragRepository()

    @Published private(set) var crags: [Crag] = []

    private let db = Firestore.firestore()
    private var collection: CollectionReference { db.collection("crags") }
    private let storage = Storage.storage()
    private var registration: ListenerRegistration?
    private var didSeed = false

    private init() {}

    func byId(_ cragId: String) -> Crag? { crags.first { $0.id == cragId } }
    func wallById(_ cragId: String, _ wallId: String) -> Wall? { byId(cragId)?.walls.first { $0.id == wallId } }

    /// Call once (e.g. from RocklenseABApp.init or on first appear of the
    /// root view). Safe to call more than once.
    func startListening() {
        guard registration == nil else { return }
        registration = collection.addSnapshotListener { [weak self] snapshot, _ in
            guard let self, let snapshot else { return }
            self.crags = snapshot.documents.compactMap { doc in
                // The document ID is authoritative -- overrides whatever id
                // is stored inside the doc, same as Android's
                // `.toObject(...)?.copy(id = doc.id)`.
                guard var crag = try? doc.data(as: Crag.self) else { return nil }
                crag.id = doc.documentID
                return crag
            }
            if snapshot.isEmpty { self.seedIfEmpty() }
        }
    }

    // MARK: Crag CRUD

    func addCrag(_ crag: Crag, completion: @escaping (Bool) -> Void = { _ in }) {
        let doc = collection.document()
        var toSave = crag
        toSave.id = doc.documentID
        do {
            try doc.setData(from: toSave) { error in completion(error == nil) }
        } catch { completion(false) }
    }

    func deleteCrag(_ cragId: String, completion: @escaping (Bool) -> Void = { _ in }) {
        collection.document(cragId).delete { error in completion(error == nil) }
    }

    func updateCragInfo(cragId: String, name: String, area: String, lat: Double, lng: Double,
                         completion: @escaping (Bool) -> Void = { _ in }) {
        collection.document(cragId).updateData([
            "name": name, "area": area, "lat": lat, "lng": lng
        ]) { error in completion(error == nil) }
    }

    /// Adds a decorative photo of the crag itself (not an AR reference photo).
    func addCragPhoto(cragId: String, image: UIImage, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let crag = byId(cragId), let data = image.jpegData(compressionQuality: 0.85) else {
            completion(false); return
        }
        let nextIndex = crag.photoUrls.count
        let ref = storage.reference().child("crag_photos/\(cragId)_\(nextIndex).jpg")
        ref.putData(data) { [weak self] _, error in
            guard let self, error == nil else { completion(false); return }
            ref.downloadURL { url, error in
                guard let url, error == nil, let latest = self.byId(cragId) else { completion(false); return }
                self.collection.document(cragId).updateData([
                    "photoUrls": latest.photoUrls + [url.absoluteString]
                ]) { error in completion(error == nil) }
            }
        }
    }

    // MARK: Wall CRUD

    func addWall(cragId: String, wall: Wall, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let crag = byId(cragId) else { completion(false); return }
        var newWall = wall
        if newWall.id.isEmpty { newWall.id = UUID().uuidString }
        let updated = crag.walls + [newWall]
        writeWalls(cragId: cragId, walls: updated, completion: completion)
    }

    func deleteWall(cragId: String, wallId: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let crag = byId(cragId) else { completion(false); return }
        writeWalls(cragId: cragId, walls: crag.walls.filter { $0.id != wallId }, completion: completion)
    }

    func updateWallName(cragId: String, wallId: String, name: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let crag = byId(cragId) else { completion(false); return }
        let updated = crag.walls.map { w -> Wall in
            var w = w; if w.id == wallId { w.name = name }; return w
        }
        writeWalls(cragId: cragId, walls: updated, completion: completion)
    }

    // MARK: Route CRUD

    func addRoute(cragId: String, wallId: String, route: Route, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let crag = byId(cragId) else { completion(false); return }
        var newRoute = route
        if newRoute.id.isEmpty { newRoute.id = UUID().uuidString }
        let updated = crag.walls.map { w -> Wall in
            var w = w; if w.id == wallId { w.routes.append(newRoute) }; return w
        }
        writeWalls(cragId: cragId, walls: updated, completion: completion)
    }

    /// Updates a route's basic metadata -- leaves clips and everything else
    /// about the wall untouched. Editing in place (rather than delete +
    /// recreate) matters specifically because deleting a route loses its AR
    /// clip mapping entirely.
    func updateRoute(cragId: String, wallId: String, routeId: String, name: String, grade: String,
                      lengthMeters: Int, boltCount: Int, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let crag = byId(cragId) else { completion(false); return }
        let updated = crag.walls.map { w -> Wall in
            guard w.id == wallId else { return w }
            var w = w
            w.routes = w.routes.map { r in
                guard r.id == routeId else { return r }
                var r = r
                r.name = name; r.grade = grade; r.lengthMeters = lengthMeters; r.boltCount = boltCount
                return r
            }
            return w
        }
        writeWalls(cragId: cragId, walls: updated, completion: completion)
    }

    func deleteRoute(cragId: String, wallId: String, routeId: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let crag = byId(cragId) else { completion(false); return }
        let updated = crag.walls.map { w -> Wall in
            var w = w; if w.id == wallId { w.routes.removeAll { $0.id == routeId } }; return w
        }
        writeWalls(cragId: cragId, walls: updated, completion: completion)
    }

    // MARK: Wall setup / mapping (the AR-authoring flow)

    /// Sets up a wall's reference photos and measured dimensions, independent
    /// of any route -- the up-front "set up this wall" step, done once before
    /// any routes are mapped on it.
    func setupWallReferencePhotos(
        cragId: String, wallId: String, photos: [UIImage],
        widthMeters: Float, heightMeters: Float,
        alignmentMarkerXFractions: [Float] = [], alignmentMarkerYFractions: [Float] = [],
        alignmentMarker2XFractions: [Float] = [], alignmentMarker2YFractions: [Float] = [],
        completion: @escaping (Bool) -> Void
    ) {
        guard !photos.isEmpty else { completion(false); return }
        uploadPhotos(photos, pathPrefix: "crag_reference_images/\(cragId)_\(wallId)_") { [weak self] urls in
            guard let self, let urls, let crag = self.byId(cragId) else { completion(false); return }
            let updated = crag.walls.map { w -> Wall in
                guard w.id == wallId else { return w }
                var w = w
                w.referenceImageUrls = urls
                w.referenceImageWidthMeters = widthMeters
                w.referenceImageHeightMeters = heightMeters
                w.alignmentMarkerXFractions = alignmentMarkerXFractions
                w.alignmentMarkerYFractions = alignmentMarkerYFractions
                w.alignmentMarker2XFractions = alignmentMarker2XFractions
                w.alignmentMarker2YFractions = alignmentMarker2YFractions
                return w
            }
            self.writeWalls(cragId: cragId, walls: updated, completion: completion)
        }
    }

    /// Saves clip points for a route on a wall that's ALREADY been mapped --
    /// no new photo, no re-measuring, just tapping the new route's bolts.
    func saveRouteClipsOnExistingWall(cragId: String, wallId: String, routeId: String,
                                       clips: [ClipPoint], completion: @escaping (Bool) -> Void) {
        guard let crag = byId(cragId) else { completion(false); return }
        let updated = crag.walls.map { w -> Wall in
            guard w.id == wallId else { return w }
            var w = w
            w.routes = w.routes.map { r in
                guard r.id == routeId else { return r }
                var r = r; r.clips = clips; return r
            }
            return w
        }
        writeWalls(cragId: cragId, walls: updated, completion: completion)
    }

    /// Adds an additional reference photo of the SAME wall (different
    /// lighting/angle) to a wall that's already been mapped once.
    func addReferenceAngle(cragId: String, wallId: String, image: UIImage, completion: @escaping (Bool) -> Void) {
        guard let crag = byId(cragId), let wall = crag.walls.first(where: { $0.id == wallId }),
              let data = image.jpegData(compressionQuality: 0.85) else { completion(false); return }
        let nextIndex = wall.referenceImageUrls.count
        let ref = storage.reference().child("crag_reference_images/\(cragId)_\(wallId)_\(nextIndex).jpg")
        ref.putData(data) { [weak self] _, error in
            guard let self, error == nil else { completion(false); return }
            ref.downloadURL { url, error in
                guard let url, error == nil, let latest = self.byId(cragId) else { completion(false); return }
                let updated = latest.walls.map { w -> Wall in
                    var w = w; if w.id == wallId { w.referenceImageUrls.append(url.absoluteString) }; return w
                }
                self.writeWalls(cragId: cragId, walls: updated, completion: completion)
            }
        }
    }

    /// Downloads and decodes ALL of a wall's reference images -- every
    /// phone-captured Storage photo plus the one bundled in the app's
    /// `ar_images/` folder, if present.
    func loadReferenceImages(wall: Wall, completion: @escaping ([UIImage]) -> Void) {
        let urls = wall.referenceImageUrls
        let assetName = wall.referenceImageAsset
        if urls.isEmpty && assetName == nil { completion([]); return }

        var results = [UIImage?](repeating: nil, count: urls.count + (assetName != nil ? 1 : 0))
        var remaining = results.count
        func finishIfDone() {
            remaining -= 1
            if remaining == 0 { completion(results.compactMap { $0 }) }
        }

        let maxBytes: Int64 = 8 * 1024 * 1024
        for (index, urlString) in urls.enumerated() {
            storage.reference(forURL: urlString).getData(maxSize: maxBytes) { data, _ in
                if let data { results[index] = UIImage(data: data) }
                finishIfDone()
            }
        }
        if let assetName {
            // ar_images must be added to Xcode as a BLUE folder reference
            // (not a yellow group), so it copies into the bundle preserving
            // its subpath -- see README_iOS.md.
            if let url = Bundle.main.url(forResource: assetName, withExtension: nil, subdirectory: "ar_images"),
               let data = try? Data(contentsOf: url) {
                results[urls.count] = UIImage(data: data)
            }
            finishIfDone()
        }
    }

    // MARK: Private helpers

    private func writeWalls(cragId: String, walls: [Wall], completion: @escaping (Bool) -> Void) {
        do {
            let encoded = try walls.map { try Firestore.Encoder().encode($0) }
            collection.document(cragId).updateData(["walls": encoded]) { error in completion(error == nil) }
        } catch {
            completion(false)
        }
    }

    private func uploadPhotos(_ photos: [UIImage], pathPrefix: String, completion: @escaping ([String]?) -> Void) {
        var urls = [String?](repeating: nil, count: photos.count)
        var remaining = photos.count
        var anyFailed = false
        for (index, photo) in photos.enumerated() {
            guard let data = photo.jpegData(compressionQuality: 0.85) else { anyFailed = true; remaining -= 1; continue }
            let ref = storage.reference().child("\(pathPrefix)\(index).jpg")
            ref.putData(data) { _, error in
                if error != nil { anyFailed = true; remaining -= 1; if remaining == 0 { completion(anyFailed ? nil : urls.compactMap { $0 }) }; return }
                ref.downloadURL { url, error in
                    if let url, error == nil { urls[index] = url.absoluteString } else { anyFailed = true }
                    remaining -= 1
                    if remaining == 0 { completion(anyFailed ? nil : urls.compactMap { $0 }) }
                }
            }
        }
    }

    /// Populates Firestore with the original six Bow Valley / Kananaskis
    /// crags the first time the app runs against an empty database -- same
    /// seed data as the Android app, so a fresh Firestore project looks
    /// identical from either platform.
    private func seedIfEmpty() {
        guard !didSeed else { return }
        didSeed = true
        for crag in Self.seedCrags { addCrag(crag) }
    }

    private static let seedCrags: [Crag] = [
        Crag(name: "Echo Canyon", area: "Canmore", lat: 51.1075, lng: -115.3592,
             blurb: "5 min from downtown Canmore. Limestone, sport, family-friendly.",
             tags: ["Limestone", "Sport", "Family-friendly"],
             walls: [Wall(id: "main-wall", name: "Main Wall",
                          referenceImageAsset: "echo_canyon_rusty_wall.jpg",
                          referenceImageWidthMeters: 8.0,
                          routes: [
                              Route(id: "kg", name: "Kid Gloves", grade: "5.6", lengthMeters: 18, boltCount: 6),
                              Route(id: "od", name: "Overhang Delight", grade: "5.9", lengthMeters: 20, boltCount: 7),
                              Route(id: "rw", name: "Rusty Wall", grade: "5.10a", lengthMeters: 22, boltCount: 8,
                                    clips: [ClipPoint(xOffsetMeters: 1.1, yOffsetMeters: 1.4),
                                            ClipPoint(xOffsetMeters: 0.6, yOffsetMeters: 3.0),
                                            ClipPoint(xOffsetMeters: 1.3, yOffsetMeters: 4.6),
                                            ClipPoint(xOffsetMeters: 0.4, yOffsetMeters: 6.1),
                                            ClipPoint(xOffsetMeters: 1.0, yOffsetMeters: 7.7),
                                            ClipPoint(xOffsetMeters: 0.7, yOffsetMeters: 9.2),
                                            ClipPoint(xOffsetMeters: 1.2, yOffsetMeters: 10.8),
                                            ClipPoint(xOffsetMeters: 0.9, yOffsetMeters: 12.2)]),
                              Route(id: "ct", name: "Chalk Talk", grade: "5.10c", lengthMeters: 22, boltCount: 8),
                              Route(id: "pc", name: "Pine Crux", grade: "5.11a", lengthMeters: 25, boltCount: 9)
                          ])]),
        Crag(name: "Grassi Lakes", area: "Canmore", lat: 51.0728, lng: -115.3567,
             blurb: "10 min from downtown Canmore. Limestone, sport, popular.",
             tags: ["Limestone", "Sport", "Popular"],
             walls: [Wall(id: "main-wall", name: "Main Wall", routes: [
                 Route(id: "ll", name: "Lakeside Layback", grade: "5.7", lengthMeters: 15, boltCount: 6),
                 Route(id: "tl", name: "Turquoise Line", grade: "5.9+", lengthMeters: 18, boltCount: 7),
                 Route(id: "gc", name: "Grassi Classic", grade: "5.10b", lengthMeters: 20, boltCount: 8),
                 Route(id: "td", name: "The Diamond", grade: "5.11c", lengthMeters: 24, boltCount: 9)
             ])]),
        Crag(name: "Heart Creek", area: "Bow Valley Provincial Park", lat: 51.0507, lng: -115.1478,
             blurb: "20 min east of Canmore. Limestone, sport, some multi-pitch.",
             tags: ["Limestone", "Sport", "Multi-pitch"],
             walls: [Wall(id: "main-wall", name: "Main Wall", routes: [
                 Route(id: "vw", name: "Valley Warmup", grade: "5.6", lengthMeters: 16, boltCount: 5),
                 Route(id: "hl", name: "Heartline", grade: "5.9", lengthMeters: 20, boltCount: 7),
                 Route(id: "ca", name: "Cardiac Arete", grade: "5.11a", lengthMeters: 22, boltCount: 8)
             ])]),
        Crag(name: "Wasootch Creek", area: "Kananaskis Country", lat: 50.9308, lng: -115.1450,
             blurb: "35 min south of Canmore. Limestone, sport, steep.",
             tags: ["Limestone", "Sport", "Steep"],
             walls: [Wall(id: "main-wall", name: "Main Wall", routes: [
                 Route(id: "cw", name: "Creekside Warmup", grade: "5.8", lengthMeters: 18, boltCount: 6),
                 Route(id: "ww", name: "Wasootch Wall", grade: "5.10d", lengthMeters: 25, boltCount: 9),
                 Route(id: "oc", name: "Overhang Central", grade: "5.12a", lengthMeters: 27, boltCount: 10)
             ])]),
        Crag(name: "Lac des Arcs (The Playground)", area: "Lac des Arcs", lat: 51.0997, lng: -115.0958,
             blurb: "15 min east of Canmore. Limestone, sport, sunny face.",
             tags: ["Limestone", "Sport", "Sunny face"],
             walls: [Wall(id: "main-wall", name: "Main Wall", routes: [
                 Route(id: "ss", name: "Sunny Slab", grade: "5.7", lengthMeters: 17, boltCount: 6),
                 Route(id: "pd", name: "Playground Direct", grade: "5.10a", lengthMeters: 20, boltCount: 8),
                 Route(id: "aa", name: "Arcs Arete", grade: "5.11b", lengthMeters: 22, boltCount: 8)
             ])]),
        Crag(name: "Grotto Canyon", area: "Bow Valley Provincial Park", lat: 51.1219, lng: -115.2153,
             blurb: "12 min east of Canmore. Limestone, sport, scenic canyon approach.",
             tags: ["Limestone", "Sport", "Scenic approach"],
             walls: [Wall(id: "main-wall", name: "Main Wall", routes: [
                 Route(id: "cm", name: "Canyon Mouth", grade: "5.8", lengthMeters: 18, boltCount: 6),
                 Route(id: "gg", name: "Grotto Groove", grade: "5.10b", lengthMeters: 20, boltCount: 7),
                 Route(id: "hc", name: "Hoodoo Crack", grade: "5.11d", lengthMeters: 23, boltCount: 9)
             ])])
    ]
}
