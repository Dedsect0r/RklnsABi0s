import AVFoundation
import SwiftUI

// MARK: - SetupWallView (SetupWallFragment port)

/// The up-front "set up this wall" step: take several photos from different
/// angles/lighting and measure the wall's real width/height, done ONCE
/// before any routes are mapped on it. After the FIRST photo, the climber
/// marks 3-4 distinctive real-world features on it; every photo after that
/// shows those same points as crosshair guides on the live camera preview.
struct SetupWallView: View {
    @EnvironmentObject var cragRepo: CragRepository
    @Environment(\.dismiss) private var dismiss

    let cragId: String
    let wallId: String

    @State private var capturedPhotos: [UIImage] = []
    @State private var firstPhoto: UIImage?
    @State private var markerX: [Float] = []
    @State private var markerY: [Float] = []
    @State private var marker2X: [Float] = []
    @State private var marker2Y: [Float] = []
    @State private var measuredWidth: Float?
    @State private var measuredHeight: Float?
    @State private var manualWidthText = ""

    @State private var showCamera = false
    @State private var showMarkPoints = false
    @State private var markSecondBar = false
    @State private var showMeasure = false
    @State private var saving = false
    @State private var errorText: String?

    private var wall: Wall? { cragRepo.wallById(cragId, wallId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Take 3\u{2013}5 photos of the wall from different angles/lighting, all from roughly the same distance you'd naturally stand at to check a route. After the first photo, you'll mark a few distinctive features (a rock corner, a crack, a chalk mark) \u{2014} every photo after that shows those as simple crosshair guides to line up. Then measure the wall's width. Do this once here, and every route mapped on this wall afterward will just need a clip placed.")
                    .font(.system(size: 13))
                    .foregroundStyle(RLColor.ink.opacity(0.75))

                Button {
                    showCamera = true
                } label: {
                    Label("Take photo", systemImage: "camera.fill")
                }
                .buttonStyle(RLPrimaryButtonStyle())

                Text(photosCapturedText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RLColor.pine)

                if !markerX.isEmpty {
                    Button {
                        markSecondBar = true
                        showMarkPoints = true
                    } label: {
                        Text(marker2X.isEmpty ? "Add a second reference bar (optional)" : "Redo second reference bar")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    if !marker2X.isEmpty {
                        Text("Second reference bar added \u{2713}")
                            .font(.system(size: 12)).foregroundStyle(RLColor.pine)
                    }
                }

                Divider()

                if ARCapability.isSupported {
                    Button {
                        showMeasure = true
                    } label: {
                        Label("Measure the wall with AR", systemImage: "ruler")
                    }
                    .buttonStyle(RLPrimaryButtonStyle(background: RLColor.pine))
                }

                Text(measuredSizeText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RLColor.pine)

                TextField("Or enter the wall's width in metres", text: $manualWidthText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)

                if let errorText {
                    Text(errorText).font(.system(size: 13)).foregroundStyle(RLColor.rust)
                }

                Button(saving ? "Saving..." : "Save wall setup") { save() }
                    .buttonStyle(RLPrimaryButtonStyle())
                    .disabled(saving)
            }
            .padding(RLMetrics.screenPadding)
        }
        .background(RLColor.limestone)
        .navigationTitle("Set up: \(wall?.name ?? "wall")")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showCamera) {
            AlignedCameraView(
                ghostImage: firstPhoto,
                markerPoints: zip(markerX, markerY).map { (CGFloat($0), CGFloat($1)) }
            ) { photo in
                capturedPhotos.append(photo)
                if firstPhoto == nil {
                    // First photo -- immediately mark alignment points on it.
                    firstPhoto = photo
                    markSecondBar = false
                    showMarkPoints = true
                }
            }
        }
        .fullScreenCover(isPresented: $showMarkPoints) {
            if let firstPhoto {
                MarkAlignmentPointsView(photo: firstPhoto) { xs, ys in
                    if markSecondBar { marker2X = xs; marker2Y = ys }
                    else { markerX = xs; markerY = ys }
                }
            }
        }
        .fullScreenCover(isPresented: $showMeasure) {
            ARMeasureScreen { width, height in
                measuredWidth = width
                measuredHeight = height
            }
        }
    }

    private var photosCapturedText: String {
        switch capturedPhotos.count {
        case 0: return "No photos yet \u{2014} take 3\u{2013}5 from different angles for reliable recognition"
        case 1, 2: return "\(capturedPhotos.count) photo\(capturedPhotos.count == 1 ? "" : "s") captured \u{2014} a few more angles will help recognition"
        default: return "\(capturedPhotos.count) photos captured \u{2713} \u{2014} take more if you like, or continue below"
        }
    }

    private var measuredSizeText: String {
        switch (measuredWidth, measuredHeight) {
        case let (w?, h?): return String(format: "Measured with AR: %.2f m wide \u{00d7} %.2f m tall", w, h)
        case let (w?, nil): return String(format: "Measured width: %.2f m (height will be estimated from the photo)", w)
        default: return "Not measured yet \u{2014} or enter width manually below"
        }
    }

    private func save() {
        let width = measuredWidth ?? Float(manualWidthText.replacingOccurrences(of: ",", with: "."))
        let height: Float? = measuredHeight ?? capturedPhotos.first.flatMap { photo in
            width.map { $0 * Float(photo.size.height / photo.size.width) }
        }
        guard !capturedPhotos.isEmpty else { errorText = "Take at least one photo first"; return }
        guard let w = width, w > 0 else {
            errorText = "Measure the wall with AR, or enter its width in metres manually"; return
        }
        guard let h = height, h > 0 else {
            errorText = "Couldn't determine the wall's height \u{2014} try measuring again"; return
        }

        saving = true
        errorText = nil
        cragRepo.setupWallReferencePhotos(
            cragId: cragId, wallId: wallId, photos: capturedPhotos,
            widthMeters: w, heightMeters: h,
            alignmentMarkerXFractions: markerX, alignmentMarkerYFractions: markerY,
            alignmentMarker2XFractions: marker2X, alignmentMarker2YFractions: marker2Y
        ) { success in
            saving = false
            if success { dismiss() }
            else { errorText = "Couldn't save \u{2014} check your connection and try again" }
        }
    }
}

// MARK: - MapRouteView (MapRouteFragment port)

/// Maps a route: places its clips, in climbing order, live in AR against the
/// wall's already-set-up reference photos. No photo capture or measuring
/// here -- that's all done once at wall-setup time.
struct MapRouteView: View {
    @EnvironmentObject var cragRepo: CragRepository
    @Environment(\.dismiss) private var dismiss

    let cragId: String
    let wallId: String
    let routeId: String

    @State private var wallPhotos: [UIImage] = []
    @State private var photosLoading = true
    @State private var placedClips: [ClipPoint] = []
    @State private var showPlaceClip = false
    @State private var saving = false
    @State private var errorText: String?
    @State private var didSeedClips = false

    private var wall: Wall? { cragRepo.wallById(cragId, wallId) }
    private var route: Route? { wall?.routes.first { $0.id == routeId } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(wall?.name ?? "This wall")'s reference photos are already set up \u{2014} once they load, place this route's clips in AR, in climbing order, starting from the first bolt.")
                    .font(.system(size: 13))
                    .foregroundStyle(RLColor.ink.opacity(0.75))

                Text(placedClipsText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RLColor.pine)

                // The button's label always names the NEXT clip about to be
                // placed -- the fix for the original "same button, confusing"
                // problem on Android.
                Button(placedClips.isEmpty ? "Place Clip 1 (first) in AR" : "Place Clip \(placedClips.count + 1) in AR") {
                    showPlaceClip = true
                }
                .buttonStyle(RLPrimaryButtonStyle())
                .disabled(photosLoading || wallPhotos.isEmpty || !ARCapability.isSupported)
                .opacity((photosLoading || wallPhotos.isEmpty || !ARCapability.isSupported) ? 0.5 : 1)

                if photosLoading {
                    Text("Loading the wall's reference photos...")
                        .font(.system(size: 12)).foregroundStyle(RLColor.inactiveText)
                } else if wallPhotos.isEmpty {
                    Text("Couldn't load the wall's reference photos \u{2014} check your connection")
                        .font(.system(size: 12)).foregroundStyle(RLColor.rust)
                }
                if !ARCapability.isSupported {
                    Text("Placing clips needs an ARKit-capable device.")
                        .font(.system(size: 12)).foregroundStyle(RLColor.rust)
                }

                if !placedClips.isEmpty {
                    Button(placedClips.count == 1 ? "Undo first clip" : "Undo last clip") {
                        placedClips.removeLast()
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RLColor.rust)
                }

                if let errorText {
                    Text(errorText).font(.system(size: 13)).foregroundStyle(RLColor.rust)
                }

                Button(saving ? "Saving..." : "Save mapping") { save() }
                    .buttonStyle(RLPrimaryButtonStyle(background: RLColor.pine))
                    .disabled(saving)
            }
            .padding(RLMetrics.screenPadding)
        }
        .background(RLColor.limestone)
        .navigationTitle("Mapping: \(route?.name ?? "route")")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .fullScreenCover(isPresented: $showPlaceClip) {
            if let wall {
                let clipNumber = placedClips.count + 1
                ARPlaceClipScreen(
                    referenceImages: wallPhotos,
                    wallWidthMeters: wall.referenceImageWidthMeters,
                    wallHeightMeters: wall.referenceImageHeightMeters,
                    clipNumber: clipNumber,
                    clipLabel: clipNumber == 1 ? "the first clip" : "clip \(clipNumber)",
                    previousClips: placedClips,
                    wall: wall
                ) { clip in
                    placedClips.append(clip)
                }
            }
        }
    }

    private var placedClipsText: String {
        switch placedClips.count {
        case 0: return "Not placed yet"
        case 1: return "1 clip placed \u{2713} (the first)"
        default: return "\(placedClips.count) clips placed \u{2713}"
        }
    }

    private func load() {
        if !didSeedClips {
            didSeedClips = true
            placedClips = route?.clips ?? []
        }
        guard let wall else { photosLoading = false; return }
        cragRepo.loadReferenceImages(wall: wall) { images in
            wallPhotos = images
            photosLoading = false
        }
    }

    private func save() {
        guard !placedClips.isEmpty else {
            errorText = "Place at least the first clip in AR first"; return
        }
        saving = true
        errorText = nil
        cragRepo.saveRouteClipsOnExistingWall(cragId: cragId, wallId: wallId, routeId: routeId,
                                               clips: placedClips) { success in
            saving = false
            if success { dismiss() }
            else { errorText = "Couldn't save \u{2014} check your connection and try again" }
        }
    }
}

// MARK: - AddAngleView (AddAngleFragment port)

/// Captures one more photo of an already-mapped wall from a different angle
/// or lighting, appended to the wall's referenceImageUrls -- no re-measuring
/// or re-tapping clip points. The wall's existing first reference photo is
/// shown as a ghost overlay so the new angle frames the exact same rectangle.
struct AddAngleView: View {
    @EnvironmentObject var cragRepo: CragRepository
    @Environment(\.dismiss) private var dismiss

    let cragId: String
    let wallId: String

    @State private var ghostImage: UIImage?
    @State private var loading = true
    @State private var showCamera = false
    @State private var saving = false
    @State private var errorText: String?

    private var wall: Wall? { cragRepo.wallById(cragId, wallId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A faint overlay of the wall's existing reference photo will show once it loads \u{2014} line your camera up with it before capturing, so this new angle frames the exact same rectangle of wall.")
                .font(.system(size: 13))
                .foregroundStyle(RLColor.ink.opacity(0.75))

            Text(loading ? "Loading the wall's existing reference photo..."
                 : ghostImage != nil ? "Ready \u{2014} tap below to take the new angle photo"
                 : "Couldn't load the wall's existing photo \u{2014} check your connection")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ghostImage != nil ? RLColor.pine : RLColor.rust)

            Button {
                showCamera = true
            } label: {
                Label("Take the new angle photo", systemImage: "camera.fill")
            }
            .buttonStyle(RLPrimaryButtonStyle())
            .disabled(ghostImage == nil || saving)
            .opacity(ghostImage == nil || saving ? 0.5 : 1)

            if let errorText {
                Text(errorText).font(.system(size: 13)).foregroundStyle(RLColor.rust)
            }

            Spacer()
        }
        .padding(RLMetrics.screenPadding)
        .background(RLColor.limestone)
        .navigationTitle("Add an angle: \(wall?.name ?? "this wall")")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadGhost)
        .fullScreenCover(isPresented: $showCamera) {
            AlignedCameraView(ghostImage: ghostImage, markerPoints: []) { photo in
                submit(photo)
            }
        }
    }

    private func loadGhost() {
        guard let wall else { loading = false; return }
        cragRepo.loadReferenceImages(wall: wall) { images in
            ghostImage = images.first
            loading = false
        }
    }

    private func submit(_ photo: UIImage) {
        saving = true
        cragRepo.addReferenceAngle(cragId: cragId, wallId: wallId, image: photo) { success in
            saving = false
            if success { dismiss() }
            else { errorText = "Couldn't save \u{2014} check your connection and try again" }
        }
    }
}

// MARK: - AlignedCameraView (AlignedCameraFragment port)

/// An in-app camera whose whole purpose is showing a semi-transparent
/// "ghost" overlay of a previous reference photo (or crosshair guide points)
/// on top of the live viewfinder, so the climber can line up a new angle
/// photo to frame the SAME rectangle of wall. AVFoundation replaces
/// CameraX, same reason it exists: the system camera can't have custom UI
/// drawn over its viewfinder.
struct AlignedCameraView: View {
    @Environment(\.dismiss) private var dismiss

    let ghostImage: UIImage?
    let markerPoints: [(CGFloat, CGFloat)]
    let onCaptured: (UIImage) -> Void

    @StateObject private var camera = CameraController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: camera.session)
                .aspectRatio(3.0 / 4.0, contentMode: .fit) // 4:3 to match Android's RATIO_4_3

            // Ghost overlay and crosshair markers are BOTH shown when both
            // are available -- same as AlignedCameraFragment, which sets the
            // ghost visible whenever a path is given and additionally draws
            // the numbered markers on top when marker fractions exist.
            if let ghostImage {
                Image(uiImage: ghostImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(0.35)
                    .allowsHitTesting(false)
            }

            if !markerPoints.isEmpty {
                GeometryReader { geo in
                    ForEach(Array(markerPoints.enumerated()), id: \.offset) { index, point in
                        CrosshairMarker(number: index + 1)
                            .position(x: point.0 * geo.size.width, y: point.1 * geo.size.height)
                    }
                }
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .allowsHitTesting(false)
            }

            VStack {
                Text(instructions)
                    .font(.system(size: 13))
                    .foregroundStyle(RLColor.chalk)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Spacer()

                HStack(spacing: 40) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(RLColor.chalk)
                    Button {
                        camera.capture { image in
                            if let image {
                                onCaptured(image)
                                dismiss()
                            }
                        }
                    } label: {
                        ZStack {
                            Circle().stroke(RLColor.chalk, lineWidth: 4).frame(width: 74, height: 74)
                            Circle().fill(RLColor.rust).frame(width: 60, height: 60)
                        }
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    private var instructions: String {
        if ghostImage != nil && !markerPoints.isEmpty {
            return "Line up the numbered crosshairs with the same real features you marked (rock corner, crack, chalk mark) \u{2014} exact framing doesn't matter, just get those points over their real spots, then capture."
        } else if ghostImage != nil {
            return "Line up the faint reference photo with what your camera sees now, then capture \u{2014} matching the framing exactly is what makes this angle useful."
        } else {
            return "Take the first photo of the wall \u{2014} straight-on, well-lit, with real visual detail. Every angle photo after this one will need to line up with it."
        }
    }
}

/// Crosshair/circle marker with a number label (AlignmentMarkerView port).
struct CrosshairMarker: View {
    let number: Int
    var body: some View {
        ZStack {
            Circle().stroke(Color(hex: 0xC1502E), lineWidth: 3).frame(width: 46, height: 46)
            Rectangle().fill(Color(hex: 0xF7F3E8)).frame(width: 22, height: 2)
            Rectangle().fill(Color(hex: 0xF7F3E8)).frame(width: 2, height: 22)
            Text("\(number)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(hex: 0xF7F3E8))
                .offset(y: -36)
        }
    }
}

/// Minimal AVFoundation capture wrapper (the CameraX ProcessCameraProvider
/// equivalent). Photos come back upright (AVCapturePhotoOutput handles EXIF
/// orientation when we re-render), downsampled to a sane max dimension --
/// the PhotoUtils.decodeAndOrientBitmap role.
final class CameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var captureCompletion: ((UIImage?) -> Void)?
    private var configured = false

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                self.configureIfNeeded()
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .photo
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    func capture(completion: @escaping (UIImage?) -> Void) {
        captureCompletion = completion
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(),
              let raw = UIImage(data: data) else {
            DispatchQueue.main.async { self.captureCompletion?(nil) }
            return
        }
        // Normalize orientation + downsample to max 1600px (PhotoUtils parity)
        // so uploads and AR reference registration stay reasonably sized.
        let normalized = raw.normalizedAndDownsampled(maxDimension: 1600)
        DispatchQueue.main.async { self.captureCompletion?(normalized) }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspect // FIT_CENTER parity, must match the ghost's fit
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

extension UIImage {
    /// Re-renders upright at a capped size -- the PhotoUtils
    /// decodeAndOrientBitmap equivalent (UIKit bakes EXIF rotation into the
    /// draw, so a re-render normalizes orientation).
    func normalizedAndDownsampled(maxDimension: CGFloat) -> UIImage {
        let largest = max(size.width, size.height)
        let scale = largest > maxDimension ? maxDimension / largest : 1
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

// MARK: - MarkAlignmentPointsView (MarkAlignmentPointsFragment + ClipPlacementView port)

/// Lets the climber tap 3-4 distinctive real-world features on the wall's
/// first reference photo -- these become the crosshair guides shown on the
/// live camera for every subsequent angle photo. Points are stored as
/// fractions of the photo's width/height (0..1), same convention as Android.
struct MarkAlignmentPointsView: View {
    @Environment(\.dismiss) private var dismiss

    let photo: UIImage
    let onDone: ([Float], [Float]) -> Void

    @State private var points: [CGPoint] = []   // fractional 0..1
    @State private var errorText: String?

    var body: some View {
        ZStack {
            RLColor.dusk.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Tap 3\u{2013}4 distinctive features on the photo \u{2014} a rock corner, a crack, a chalk mark. These become the crosshair guides for every later angle photo.")
                    .font(.system(size: 13))
                    .foregroundStyle(RLColor.cream70)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)

                GeometryReader { geo in
                    let imageAspect = photo.size.width / photo.size.height
                    let fitWidth = min(geo.size.width, geo.size.height * imageAspect)
                    let fitHeight = fitWidth / imageAspect
                    ZStack {
                        Image(uiImage: photo)
                            .resizable()
                            .frame(width: fitWidth, height: fitHeight)

                        // Dashed connector line between points, in tap order.
                        if points.count > 1 {
                            Path { path in
                                let px = points.map { CGPoint(x: $0.x * fitWidth, y: $0.y * fitHeight) }
                                path.move(to: px[0])
                                for p in px.dropFirst() { path.addLine(to: p) }
                            }
                            .stroke(Color(hex: 0xF7F3E8),
                                    style: StrokeStyle(lineWidth: 3, dash: [10, 7]))
                        }
                        ForEach(Array(points.enumerated()), id: \.offset) { index, p in
                            ZStack {
                                Circle().fill(Color(hex: 0xF7F3E8)).frame(width: index == 0 ? 34 : 22)
                                if index == 0 {
                                    Circle().stroke(Color(hex: 0xC1502E), lineWidth: 4).frame(width: 34)
                                }
                                Text("\(index + 1)").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                            }
                            .position(x: p.x * fitWidth, y: p.y * fitHeight)
                        }
                    }
                    .frame(width: fitWidth, height: fitHeight)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        // Local space IS the fitted image's space -- store as
                        // resolution-independent fractions (0..1).
                        let fx = location.x / fitWidth
                        let fy = location.y / fitHeight
                        guard fx >= 0, fx <= 1, fy >= 0, fy <= 1 else { return }
                        points.append(CGPoint(x: fx, y: fy))
                    }
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }

                if let errorText {
                    Text(errorText).font(.system(size: 13)).foregroundStyle(RLColor.rust)
                }

                HStack(spacing: 12) {
                    Button("Undo") { if !points.isEmpty { points.removeLast() } }
                        .buttonStyle(RLPrimaryButtonStyle(background: RLColor.dusk2))
                    Button("Done") {
                        guard points.count >= 2 else { errorText = "Mark at least 2 points"; return }
                        onDone(points.map { Float($0.x) }, points.map { Float($0.y) })
                        dismiss()
                    }
                    .buttonStyle(RLPrimaryButtonStyle())
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
    }
}
