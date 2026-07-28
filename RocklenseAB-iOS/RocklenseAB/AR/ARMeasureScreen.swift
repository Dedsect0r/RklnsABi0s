import ARKit
import RealityKit
import SwiftUI

/// A live-AR "measuring tape": tap two points on the real wall to measure its
/// width, confirm, then do the same for height -- both come back as
/// real-world metre values. Direct port of MeasureWallFragment +
/// MeasureArRenderer: each tap raycasts against whatever ARKit can resolve at
/// that screen position (an existing plane first, falling back to an
/// estimated plane) so it works before ARKit has fully mapped the wall, and
/// the straight-line 3D distance between the two anchors is the measurement.
struct ARMeasureScreen: View {
    @Environment(\.dismiss) private var dismiss

    /// (widthMeters, heightMeters) once both stages are confirmed.
    let onMeasured: (Float, Float) -> Void

    private enum Stage { case width, height }
    @State private var stage: Stage = .width
    @State private var statusText = "Move the phone slowly so ARKit can map the surface..."
    @State private var pendingResult: Float?
    @State private var measuredWidth: Float?
    @State private var resetToken = 0   // bump to clear anchors in the container

    var body: some View {
        ZStack {
            ARMeasureContainer(
                resetToken: resetToken,
                onDistanceMeasured: { distance in
                    pendingResult = distance
                    statusText = String(format: "Measured: %.2f m \u{2014} looks right?", distance)
                },
                onStatusChanged: { statusText = $0 }
            )
            .ignoresSafeArea()

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

                VStack(spacing: 12) {
                    Text(stage == .width
                         ? "Measuring WIDTH: tap the left edge of the wall, then the right edge"
                         : "Measuring HEIGHT: tap the bottom edge of the wall, then the top edge")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RLColor.chalk)
                        .multilineTextAlignment(.center)

                    Text(statusText)
                        .font(.system(size: 13))
                        .foregroundStyle(RLColor.cream70)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 12) {
                        Button("Retry") {
                            resetToken += 1
                            pendingResult = nil
                            statusText = ""
                        }
                        .buttonStyle(RLPrimaryButtonStyle(background: RLColor.dusk2, foreground: RLColor.chalk))

                        Button("Confirm") { confirm() }
                            .buttonStyle(RLPrimaryButtonStyle())
                            .disabled(pendingResult == nil)
                            .opacity(pendingResult == nil ? 0.5 : 1)
                    }
                }
                .padding(16)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .navigationBarHidden(true)
    }

    private func confirm() {
        guard let distance = pendingResult else { return }
        if stage == .width {
            measuredWidth = distance
            stage = .height
            resetToken += 1
            pendingResult = nil
            statusText = ""
        } else if let width = measuredWidth {
            onMeasured(width, distance)
            dismiss()
        }
    }
}

private struct ARMeasureContainer: UIViewRepresentable {
    let resetToken: Int
    let onDistanceMeasured: (Float) -> Void
    let onStatusChanged: (String) -> Void

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false
        let config = ARWorldTrackingConfiguration()
        // Same plane scope as Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL.
        config.planeDetection = [.horizontal, .vertical]
        config.isAutoFocusEnabled = true
        arView.session.run(config)
        arView.session.delegate = context.coordinator
        context.coordinator.arView = arView

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                          action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tap)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        if context.coordinator.lastResetToken != resetToken {
            context.coordinator.lastResetToken = resetToken
            context.coordinator.reset()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDistanceMeasured: onDistanceMeasured, onStatusChanged: onStatusChanged)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        weak var arView: ARView?
        var lastResetToken = 0
        private let onDistanceMeasured: (Float) -> Void
        private let onStatusChanged: (String) -> Void

        private var firstAnchor: AnchorEntity?
        private var secondAnchor: AnchorEntity?
        private var reportedReady = false

        init(onDistanceMeasured: @escaping (Float) -> Void, onStatusChanged: @escaping (String) -> Void) {
            self.onDistanceMeasured = onDistanceMeasured
            self.onStatusChanged = onStatusChanged
        }

        /// Clears both points so the climber can measure again (width, then height).
        func reset() {
            if let a = firstAnchor { arView?.scene.removeAnchor(a) }
            if let b = secondAnchor { arView?.scene.removeAnchor(b) }
            firstAnchor = nil
            secondAnchor = nil
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let ready = frame.camera.trackingState == .normal
            if ready != reportedReady {
                reportedReady = ready
                if !ready {
                    DispatchQueue.main.async {
                        self.onStatusChanged("Move the phone slowly so ARKit can map the surface...")
                    }
                }
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView else { return }
            guard secondAnchor == nil else { return } // completed measurement -- reset first

            let point = gesture.location(in: arView)
            // Prefer an existing detected plane (most stable), fall back to an
            // estimated plane so this still works on a wall ARKit hasn't fully
            // recognized -- same two-tier preference as the Android hitTest.
            let result = arView.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .any).first
                ?? arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first

            guard let result else {
                onStatusChanged("Couldn't get a fix there \u{2014} try tapping a more textured part of the wall")
                return
            }

            let anchor = AnchorEntity(world: result.worldTransform)
            let isFirst = firstAnchor == nil
            // Same as MeasureArRenderer: chalk dot for point 1, clay dot for
            // point 2, drawn at the SAME size (both 40px on Android).
            let dot = isFirst
                ? ARMarkerFactory.clipDot(radius: 0.03)
                : ARMarkerFactory.clipDot(color: UIColor(red: 0.757, green: 0.314, blue: 0.180, alpha: 1),
                                           radius: 0.03)
            anchor.addChild(dot)
            arView.scene.addAnchor(anchor)

            if isFirst {
                firstAnchor = anchor
                onStatusChanged("First point placed \u{00b7} now tap the second point")
            } else {
                secondAnchor = anchor
                let p1 = firstAnchor!.position(relativeTo: nil)
                let p2 = anchor.position(relativeTo: nil)
                let distance = length(p1 - p2)
                onStatusChanged(String(format: "Measured %.2f m", distance))
                onDistanceMeasured(distance)
            }
        }
    }
}
