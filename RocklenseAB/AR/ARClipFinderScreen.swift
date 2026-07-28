import ARKit
import RealityKit
import SwiftUI

/// The Clip Finder camera: ARKit image tracking localizes the selected
/// wall's reference photo(s), then the selected route's clip positions are
/// drawn anchored to the wall -- the first clip gets the grade-label pill,
/// every clip after shows as a small chalk dot. Direct port of
/// ArClipFinderFragment + ArGlRenderer's behavior:
///
///  - ONLY this wall's reference photos are loaded as detection images (not
///    every mapped wall) -- same "scope the recognition database to just
///    this wall" decision, for the same reliability reasons.
///  - The wall's pose is re-synced EVERY frame it's recognized, not locked
///    once -- re-anchoring to a fresh recognition each time the wall is in
///    view is what corrects accumulated drift instead of compounding it.
///    ARKit's ARImageAnchor does this continuously when
///    `maximumNumberOfTrackedImages > 0`, and we additionally hide markers
///    whenever the anchor stops being actively tracked so a stale pose is
///    never presented as trustworthy.
///  - While the wall isn't recognized: dark scrim + the wall's saved
///    alignment guide line (AlignmentGuideOverlay), sliding away on lock.
struct ARClipFinderScreen: View {
    @EnvironmentObject var cragRepo: CragRepository
    @Environment(\.dismiss) private var dismiss

    let cragId: String
    let wallId: String
    let routeId: String

    @State private var statusText = "Point your camera at the wall's reference photo to align"
    @State private var isTracking = false
    @State private var referenceImages: [UIImage]? = nil
    @State private var loadFailed = false
    @State private var loadedForPhotoCount = -1

    private var wall: Wall? { cragRepo.wallById(cragId, wallId) }
    private var route: Route? { wall?.routes.first { $0.id == routeId } }

    var body: some View {
        ZStack {
            if let images = referenceImages, let wall, let route {
                ARClipFinderContainer(
                    referenceImages: images,
                    imageWidthMeters: wall.referenceImageWidthMeters,
                    imageHeightMeters: wall.referenceImageHeightMeters,
                    clips: route.clips,
                    grade: route.grade,
                    onTrackingChanged: { tracking in
                        isTracking = tracking
                        statusText = tracking
                            ? "Tracking \u{00b7} first clip shows the route grade"
                            : "Point your camera at the wall's reference photo to align"
                        // Recorded on EVERY lost->tracking transition, same as
                        // ArClipFinderFragment (recordRecentClimb dedupes and
                        // moves the entry to the front, so re-acquisitions
                        // just refresh its recency).
                        if tracking {
                            LocalProfileStore.recordRecentClimb(cragId: cragId, wallId: wallId, routeId: routeId)
                        }
                    }
                )
                // Identity tied to the photo count -- if an angle is added
                // from another device/screen while this camera is open, the
                // container (and its ARKit session + detection-image set) is
                // rebuilt to include it, mirroring
                // rebuildSessionIfWallDataChanged on Android.
                .id(images.count)
                .ignoresSafeArea()

                // Dark scrim + saved alignment guide bars while not tracking,
                // exactly like the Android screen's scrim + brackets.
                ARAlignmentOverlay(wall: wall, isTracking: isTracking)
            } else {
                RLColor.dusk.ignoresSafeArea()
                if loadFailed {
                    Text("Couldn't load this wall's reference photos \u{2014} check your connection")
                        .foregroundStyle(RLColor.cream70)
                        .multilineTextAlignment(.center)
                        .padding(40)
                } else {
                    ProgressView().tint(RLColor.chalk)
                }
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(RLColor.chalk)
                            .padding(12)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)

                Spacer()

                VStack(spacing: 6) {
                    if let route {
                        Text("\(route.name) (\(route.grade))")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(RLColor.chalk)
                    }
                    Text(statusText)
                        .font(.system(size: 14))
                        .foregroundStyle(RLColor.cream70)
                        .multilineTextAlignment(.center)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .navigationBarHidden(true)
        .onAppear(perform: loadImages)
        .onChange(of: cragRepo.crags) { _ in
            // If the route/wall was deleted mid-session, don't leave the
            // climber on a dead camera screen (mirrors updateSelectionLabel's
            // pop-on-missing behavior).
            if route == nil { dismiss(); return }
            // If this wall's photo count changed (e.g. an angle was added
            // elsewhere while this screen was open), reload -- the .id() on
            // the container then rebuilds the session with the new image set.
            let currentCount = wall?.referenceImageUrls.count ?? 0
            if currentCount != loadedForPhotoCount { loadImages() }
        }
    }

    private func loadImages() {
        guard let wall, wall.isMapped else { loadFailed = true; return }
        loadedForPhotoCount = wall.referenceImageUrls.count
        cragRepo.loadReferenceImages(wall: wall) { images in
            if images.isEmpty { loadFailed = true } else { referenceImages = images }
        }
    }
}

// MARK: - The ARView container (UIViewRepresentable)

private struct ARClipFinderContainer: UIViewRepresentable {
    let referenceImages: [UIImage]
    let imageWidthMeters: Float
    let imageHeightMeters: Float
    let clips: [ClipPoint]
    let grade: String
    let onTrackingChanged: (Bool) -> Void

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false
        context.coordinator.arView = arView
        context.coordinator.configure(
            images: referenceImages,
            widthMeters: imageWidthMeters
        )
        arView.session.delegate = context.coordinator
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.clips = clips
        context.coordinator.grade = grade
        context.coordinator.imageWidthMeters = imageWidthMeters
        context.coordinator.imageHeightMeters = imageHeightMeters
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTrackingChanged: onTrackingChanged, clips: clips, grade: grade,
                    imageWidthMeters: imageWidthMeters, imageHeightMeters: imageHeightMeters)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        weak var arView: ARView?
        var clips: [ClipPoint]
        var grade: String
        var imageWidthMeters: Float
        var imageHeightMeters: Float
        private let onTrackingChanged: (Bool) -> Void

        private var wallAnchorEntity: AnchorEntity?
        private var markerEntities: [ModelEntity] = []
        private var gradeEntity: ModelEntity?
        /// The first clip's anchor-local position -- the base the billboarded
        /// label is re-derived from every frame (see didUpdate frame).
        private var gradeBasePosition = SIMD3<Float>(0, 0, 0)
        private var lastReportedTracking: Bool?

        init(onTrackingChanged: @escaping (Bool) -> Void, clips: [ClipPoint], grade: String,
             imageWidthMeters: Float, imageHeightMeters: Float) {
            self.onTrackingChanged = onTrackingChanged
            self.clips = clips
            self.grade = grade
            self.imageWidthMeters = imageWidthMeters
            self.imageHeightMeters = imageHeightMeters
        }

        func configure(images: [UIImage], widthMeters: Float) {
            guard let arView else { return }
            var referenceImages = Set<ARReferenceImage>()
            for (index, image) in images.enumerated() {
                guard let cg = image.cgImage else { continue }
                // physicalWidth is what scales tracking -- same role as
                // AugmentedImageDatabase.addImage's widthInMeters argument.
                let ref = ARReferenceImage(cg, orientation: .up, physicalWidth: CGFloat(widthMeters))
                ref.name = "wall#\(index)"
                referenceImages.insert(ref)
            }
            let config = ARWorldTrackingConfiguration()
            config.detectionImages = referenceImages
            // >0 keeps ARKit ACTIVELY re-estimating the image's pose every
            // frame it's visible (image *tracking*), rather than one-shot
            // *detection* that locks a pose at first sight -- the ARKit
            // equivalent of the Android renderer's re-sync-every-frame fix
            // for accumulated drift.
            config.maximumNumberOfTrackedImages = max(1, referenceImages.count)
            config.isAutoFocusEnabled = true
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }

        // MARK: ARSessionDelegate

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            for anchor in anchors {
                guard let imageAnchor = anchor as? ARImageAnchor else { continue }
                attachMarkers(to: imageAnchor)
            }
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            for anchor in anchors {
                guard let imageAnchor = anchor as? ARImageAnchor else { continue }
                // isTracked=false means ARKit is coasting on an old pose --
                // treat as "wall lost" and hide markers rather than showing a
                // possibly-drifted position as trustworthy (mirrors the
                // Android "only draw while actively tracked" rule).
                reportTracking(imageAnchor.isTracked)
                wallAnchorEntity?.isEnabled = imageAnchor.isTracked
            }
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // Billboard the grade label toward the camera each frame, then
            // nudge it up by 0.9x its height along the CAMERA's up vector --
            // the exact same billboard + verticalNudge treatment as
            // GradeLabelRenderer, so the label sits just over the first
            // clip's marker rather than centered directly on it.
            guard let gradeEntity, let gradeAnchor = wallAnchorEntity, gradeAnchor.isEnabled else { return }
            let camTransform = frame.camera.transform
            let camPos = SIMD3<Float>(camTransform.columns.3.x, camTransform.columns.3.y, camTransform.columns.3.z)
            let camUp = normalize(SIMD3<Float>(camTransform.columns.1.x, camTransform.columns.1.y, camTransform.columns.1.z))

            // Anchor the label's base position at the clip, then offset in
            // world space along camera-up before facing the camera.
            let clipWorld = gradeAnchor.convert(position: gradeBasePosition, to: nil)
            let nudged = clipWorld + camUp * ARMarkerFactory.gradeLabelVerticalNudge
            gradeEntity.setPosition(nudged, relativeTo: nil)
            gradeEntity.look(at: camPos, from: nudged, relativeTo: nil)
            // look(at:) points -Z at the target; the textured plane faces +Z,
            // so flip it around to face the camera.
            gradeEntity.orientation = simd_mul(gradeEntity.orientation, simd_quatf(angle: .pi, axis: [0, 1, 0]))
        }

        private func attachMarkers(to imageAnchor: ARImageAnchor) {
            guard let arView else { return }
            // A later recognition of a DIFFERENT angle photo of the same wall
            // creates a new anchor -- move the markers to the freshest one.
            if let existing = wallAnchorEntity {
                arView.scene.removeAnchor(existing)
            }
            // RealityKit doesn't have an AnchorEntity(anchor:) initializer
            // that takes an ARAnchor directly -- instead you anchor by the
            // ARKit anchor's identifier, and RealityKit tracks it
            // automatically since it's on the same ARSession backing this
            // ARView.
            let anchorEntity = AnchorEntity(.anchor(identifier: imageAnchor.identifier))
            markerEntities = []

            for (index, clip) in clips.enumerated() {
                let local = ARWallMath.anchorLocalPosition(
                    clip: clip, imageWidthMeters: imageWidthMeters, imageHeightMeters: imageHeightMeters)
                if index == 0 {
                    // First clip: the grade-label billboard instead of a dot.
                    // Parented to the anchor (so it hides with tracking loss
                    // and follows the live pose), but its world position and
                    // orientation are re-derived every frame in
                    // didUpdate(frame:) with the camera-up nudge.
                    gradeBasePosition = local
                    let label = ARMarkerFactory.gradeLabel(text: grade)
                    label.position = local
                    anchorEntity.addChild(label)
                    gradeEntity = label
                } else {
                    let dot = ARMarkerFactory.clipDot()
                    dot.position = local
                    anchorEntity.addChild(dot)
                    markerEntities.append(dot)
                }
            }
            arView.scene.addAnchor(anchorEntity)
            wallAnchorEntity = anchorEntity
            reportTracking(true)
        }

        private func reportTracking(_ tracking: Bool) {
            guard tracking != lastReportedTracking else { return }
            lastReportedTracking = tracking
            DispatchQueue.main.async { self.onTrackingChanged(tracking) }
        }
    }
}

// MARK: - Alignment guide overlay (AlignmentGuideBracketsView + scrim port)

/// The dark scrim + saved alignment guide line(s) shown while the wall isn't
/// recognized -- the guide is ONE continuous straight-segment line connecting
/// the wall's saved alignment points in tap order, which grows in on entrance
/// and slides off along its own final segment once tracking locks (the
/// "snake exits along its own path" motion from AlignmentGuideBracketsView).
struct ARAlignmentOverlay: View {
    let wall: Wall
    let isTracking: Bool

    @State private var entrance: CGFloat = 0

    private var points1: [CGPoint] {
        zip(wall.alignmentMarkerXFractions, wall.alignmentMarkerYFractions)
            .map { CGPoint(x: CGFloat($0), y: CGFloat($1)) }
    }
    private var points2: [CGPoint] {
        zip(wall.alignmentMarker2XFractions, wall.alignmentMarker2YFractions)
            .map { CGPoint(x: CGFloat($0), y: CGFloat($1)) }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(isTracking ? 0 : 0.45)
                .animation(.easeInOut(duration: isTracking ? 0.5 : 0.3).delay(isTracking ? 0.5 : 0), value: isTracking)
                .allowsHitTesting(false)
                .ignoresSafeArea()

            if points1.count >= 2 {
                GuideLine(points: points1, entrance: entrance, exited: isTracking)
            }
            if points2.count >= 2 {
                GuideLine(points: points2, entrance: entrance, exited: isTracking)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { entrance = 1 }
        }
    }

    private struct GuideLine: View {
        let points: [CGPoint]
        let entrance: CGFloat
        let exited: Bool

        var body: some View {
            GeometryReader { geo in
                let last = points[points.count - 1]
                let secondLast = points[points.count - 2]
                let dir = CGVector(dx: last.x - secondLast.x, dy: last.y - secondLast.y)
                let len = max(0.0001, sqrt(dir.dx * dir.dx + dir.dy * dir.dy))
                let exitOffset = exited ? CGSize(width: dir.dx / len * 1.3 * geo.size.width,
                                                  height: dir.dy / len * 1.3 * geo.size.height) : .zero

                Path { path in
                    let px = points.map { CGPoint(x: $0.x * geo.size.width, y: $0.y * geo.size.height) }
                    path.move(to: px[0])
                    for p in px.dropFirst() { path.addLine(to: p) }
                }
                .trim(from: 0, to: entrance)
                .stroke(Color(hex: 0xF7F3E8), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                .offset(exitOffset)
                .animation(.easeIn(duration: exited ? 0.9 : 0.6), value: exited)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }
}
