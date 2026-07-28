import ARKit
import RealityKit
import SwiftUI

/// Places one clip (any clip in a route, in climbing order) by tapping its
/// real position directly in a live AR view. Direct port of
/// PlaceStartClipFragment + PlaceStartClipRenderer:
///
///  - DEPTH: rather than trust generic raycasting for the tapped point's
///    distance, the tap ray is intersected with the WALL'S OWN KNOWN PLANE
///    (the tracked reference image's pose + its normal). Exact geometry
///    rather than an estimate -- the fix for the original "floating dot" bug.
///  - DRIFT: the marker's on-screen position is re-derived from the stored
///    OFFSET plus the wall's CURRENT pose every frame (RealityKit does this
///    automatically since the marker entity is a child of the live image
///    anchor), and markers are hidden whenever the wall isn't actively
///    tracked this frame, so a stale pose is never shown as trustworthy.
///  - Clips already placed earlier in this session render as small dimmed
///    reference markers for spatial continuity between clip 1, 2, 3...
struct ARPlaceClipScreen: View {
    @Environment(\.dismiss) private var dismiss

    let referenceImages: [UIImage]
    let wallWidthMeters: Float
    let wallHeightMeters: Float
    let clipNumber: Int
    let clipLabel: String
    let previousClips: [ClipPoint]
    let wall: Wall?   // for the alignment guide overlay
    let onPlaced: (ClipPoint) -> Void

    @State private var statusText = "Point your camera at the wall"
    @State private var isTracking = false
    @State private var currentOffset: ClipPoint?

    var body: some View {
        ZStack {
            ARPlaceClipContainer(
                referenceImages: referenceImages,
                imageWidthMeters: wallWidthMeters,
                imageHeightMeters: wallHeightMeters,
                previousClips: previousClips,
                onClipPlaced: { x, y in
                    currentOffset = ClipPoint(xOffsetMeters: x, yOffsetMeters: y)
                },
                onStatusChanged: { status, tracking in
                    statusText = status
                    isTracking = tracking
                }
            )
            .ignoresSafeArea()

            if let wall {
                ARAlignmentOverlay(wall: wall, isTracking: isTracking)
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
                    Text("Placing Clip \(clipNumber)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(RLColor.chalk)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.35), in: Capsule())
                }
                .padding(.horizontal, 16)

                Spacer()

                VStack(spacing: 12) {
                    Text(statusText)
                        .font(.system(size: 14))
                        .foregroundStyle(RLColor.cream70)
                        .multilineTextAlignment(.center)

                    Button("Confirm this position") {
                        if let offset = currentOffset {
                            onPlaced(offset)
                            dismiss()
                        }
                    }
                    .buttonStyle(RLPrimaryButtonStyle())
                    .disabled(currentOffset == nil)
                    .opacity(currentOffset == nil ? 0.5 : 1)
                }
                .padding(16)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            statusText = "Point your camera at the wall to align with any of its reference photos, then tap \(clipLabel)'s real position once recognised."
        }
    }
}

private struct ARPlaceClipContainer: UIViewRepresentable {
    let referenceImages: [UIImage]
    let imageWidthMeters: Float
    let imageHeightMeters: Float
    let previousClips: [ClipPoint]
    let onClipPlaced: (Float, Float) -> Void
    let onStatusChanged: (String, Bool) -> Void

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false
        context.coordinator.arView = arView

        var refs = Set<ARReferenceImage>()
        for (index, image) in referenceImages.enumerated() {
            guard let cg = image.cgImage else { continue }
            let ref = ARReferenceImage(cg, orientation: .up, physicalWidth: CGFloat(imageWidthMeters))
            ref.name = "wall#\(index)"
            refs.insert(ref)
        }
        let config = ARWorldTrackingConfiguration()
        config.detectionImages = refs
        config.maximumNumberOfTrackedImages = max(1, refs.count)
        config.planeDetection = [.horizontal, .vertical]
        config.isAutoFocusEnabled = true
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        arView.session.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                          action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tap)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(imageWidthMeters: imageWidthMeters, imageHeightMeters: imageHeightMeters,
                    previousClips: previousClips, onClipPlaced: onClipPlaced, onStatusChanged: onStatusChanged)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        weak var arView: ARView?
        private let imageWidthMeters: Float
        private let imageHeightMeters: Float
        private let previousClips: [ClipPoint]
        private let onClipPlaced: (Float, Float) -> Void
        private let onStatusChanged: (String, Bool) -> Void

        /// The tracked wall's live anchor -- markers hang off this so
        /// RealityKit re-derives their world positions from the wall's
        /// CURRENT pose every frame automatically.
        private var wallAnchorEntity: AnchorEntity?
        private var trackedImageAnchor: ARImageAnchor?
        private var placedDot: ModelEntity?
        private var everTracked = false
        private var lastReportedTracking: Bool?

        init(imageWidthMeters: Float, imageHeightMeters: Float, previousClips: [ClipPoint],
             onClipPlaced: @escaping (Float, Float) -> Void,
             onStatusChanged: @escaping (String, Bool) -> Void) {
            self.imageWidthMeters = imageWidthMeters
            self.imageHeightMeters = imageHeightMeters
            self.previousClips = previousClips
            self.onClipPlaced = onClipPlaced
            self.onStatusChanged = onStatusChanged
        }

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            for anchor in anchors {
                guard let imageAnchor = anchor as? ARImageAnchor else { continue }
                attach(to: imageAnchor)
            }
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            for anchor in anchors {
                guard let imageAnchor = anchor as? ARImageAnchor, imageAnchor == trackedImageAnchor else { continue }
                wallAnchorEntity?.isEnabled = imageAnchor.isTracked
                report(tracking: imageAnchor.isTracked)
            }
        }

        private func attach(to imageAnchor: ARImageAnchor) {
            guard let arView else { return }
            if let existing = wallAnchorEntity { arView.scene.removeAnchor(existing) }
            let anchorEntity = AnchorEntity(world: imageAnchor.transform)

            // Already-placed clips from earlier in this session -- smaller,
            // dimmer, so the CURRENT placement still reads as the active one.
            for clip in previousClips {
                let dot = ARMarkerFactory.previousDot()
                dot.position = ARWallMath.anchorLocalPosition(
                    clip: clip, imageWidthMeters: imageWidthMeters, imageHeightMeters: imageHeightMeters)
                anchorEntity.addChild(dot)
            }

            arView.scene.addAnchor(anchorEntity)
            wallAnchorEntity = anchorEntity
            trackedImageAnchor = imageAnchor
            everTracked = true
            report(tracking: true)
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView else { return }
            guard let imageAnchor = trackedImageAnchor, imageAnchor.isTracked,
                  let anchorEntity = wallAnchorEntity else {
                onStatusChanged("Point at the wall's reference photo first, then tap", false)
                return
            }

            let point = gesture.location(in: arView)
            // Un-project the tap into a world-space ray, then intersect with
            // the wall's own plane -- the exact-geometry approach ported from
            // intersectTapWithWallPlane. ARView.ray(through:) gives us the
            // camera-origin ray directly (replacing the hand-written inverse
            // view-projection math).
            guard let ray = arView.ray(through: point) else {
                onStatusChanged("Aim more directly at the wall and try tapping again", true)
                return
            }
            guard let worldHit = ARWallMath.intersectRayWithWallPlane(
                rayOrigin: ray.origin, rayDirection: ray.direction,
                wallTransform: imageAnchor.transform
            ) else {
                onStatusChanged("Aim more directly at the wall and try tapping again", true)
                return
            }

            let local = ARWallMath.worldToAnchorLocal(worldHit, wallTransform: imageAnchor.transform)
            let offset = ARWallMath.storedOffset(anchorLocal: local,
                                                  imageWidthMeters: imageWidthMeters,
                                                  imageHeightMeters: imageHeightMeters)

            // Re-place (or create) the active clay dot -- stored as an
            // anchor-local offset so it stays glued to the wall's live pose.
            if placedDot == nil {
                let dot = ARMarkerFactory.activeDot()
                anchorEntity.addChild(dot)
                placedDot = dot
            }
            placedDot?.position = SIMD3<Float>(local.x, 0, local.z)

            onClipPlaced(offset.x, offset.y)
            onStatusChanged("Placed \u{2014} move to another angle to check it, tap again to correct", true)
        }

        private func report(tracking: Bool) {
            guard tracking != lastReportedTracking else { return }
            lastReportedTracking = tracking
            let message: String
            if tracking {
                message = "Wall recognised \u{2014} tap the bolt's real position on screen"
            } else if everTracked {
                message = "Wall lost \u{2014} point back at the reference photo"
            } else {
                message = "Point your camera at the wall"
            }
            DispatchQueue.main.async { self.onStatusChanged(message, tracking) }
        }
    }
}
