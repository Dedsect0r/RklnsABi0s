import ARKit
import RealityKit
import simd

/// Shared AR helpers for the three AR experiences (Clip Finder, wall
/// measuring, clip placement). These two functions are the LITERAL
/// formula-for-formula port of the Android renderers' coordinate math, and
/// keeping them identical is what makes cross-platform wall data work:
///
///  - ArGlRenderer / PlaceStartClipRenderer RENDER a stored clip at
///    anchor-local `(clip.x - halfWidth, 0, clip.y - halfHeight)`.
///  - PlaceStartClipRenderer STORES a tapped anchor-local point as
///    `(local.x + halfWidth, local.z + halfHeight)`.
///
/// ARKit's ARImageAnchor uses the same local frame convention as ARCore's
/// AugmentedImage (origin at the image center, X along the image
/// horizontally, Y as the surface normal out of the image face, Z spanning
/// the image vertically), so porting the formulas verbatim -- same signs,
/// same half-size shifts -- means a clip placed on either platform lands at
/// the same physical spot on both. Do NOT "correct" the Z sign here based on
/// reasoning about which way Z points: whatever direction it physically is,
/// it's the SAME direction on both platforms, and matching Android's
/// formulas exactly is the compatibility guarantee. (Field-check once
/// against an Android phone side by side -- see README_iOS.md.)
enum ARWallMath {

    /// Stored ClipPoint -> position in the tracked image anchor's local
    /// coordinate space. Mirrors `Pose.makeTranslation(clip.x - halfWidth,
    /// 0, clip.y - halfHeight)` from ArGlRenderer/PlaceStartClipRenderer.
    static func anchorLocalPosition(clip: ClipPoint, imageWidthMeters: Float, imageHeightMeters: Float) -> SIMD3<Float> {
        let halfW = imageWidthMeters / 2
        let halfH = imageHeightMeters / 2
        return SIMD3<Float>(clip.xOffsetMeters - halfW, 0, clip.yOffsetMeters - halfH)
    }

    /// Anchor-local point -> stored ClipPoint offset. Mirrors
    /// `lastOffsetXMeters = localPose.tx() + halfWidth;
    ///  lastOffsetYMeters = localPose.tz() + halfHeight`
    /// from PlaceStartClipRenderer. Inverse of the above.
    static func storedOffset(anchorLocal p: SIMD3<Float>, imageWidthMeters: Float, imageHeightMeters: Float) -> (x: Float, y: Float) {
        let halfW = imageWidthMeters / 2
        let halfH = imageHeightMeters / 2
        return (p.x + halfW, p.z + halfH)
    }

    /// Casts a ray from the camera through a screen point and intersects it
    /// with the tracked wall's plane -- the wall's plane is defined by the
    /// image anchor's position and its local Y axis (the surface normal),
    /// exactly the same geometry as PlaceStartClipRenderer's
    /// intersectTapWithWallPlane. Returns the intersection in WORLD space,
    /// or nil if the ray is near-parallel to the wall or hits behind the
    /// camera.
    static func intersectRayWithWallPlane(
        rayOrigin: SIMD3<Float>, rayDirection: SIMD3<Float>, wallTransform: simd_float4x4
    ) -> SIMD3<Float>? {
        let planePoint = SIMD3<Float>(wallTransform.columns.3.x, wallTransform.columns.3.y, wallTransform.columns.3.z)
        let planeNormal = normalize(SIMD3<Float>(wallTransform.columns.1.x, wallTransform.columns.1.y, wallTransform.columns.1.z))
        let dir = normalize(rayDirection)
        let denom = dot(dir, planeNormal)
        if abs(denom) < 0.0001 { return nil }        // ray ~parallel to the wall
        let t = dot(planePoint - rayOrigin, planeNormal) / denom
        if t < 0 { return nil }                       // behind the camera
        return rayOrigin + dir * t
    }

    /// World-space position -> the wall anchor's local space.
    static func worldToAnchorLocal(_ world: SIMD3<Float>, wallTransform: simd_float4x4) -> SIMD3<Float> {
        let inv = wallTransform.inverse
        let p4 = inv * SIMD4<Float>(world.x, world.y, world.z, 1)
        return SIMD3<Float>(p4.x, p4.y, p4.z)
    }
}

/// Whether this device can run the AR experiences at all -- the runtime gate
/// that replaces Android's ARCore-required manifest flag now that AR is
/// optional (Map/Profile still work without it).
enum ARCapability {
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }
}

// MARK: - RealityKit entity factories (the MarkerRenderer / GradeLabelRenderer equivalents)

enum ARMarkerFactory {

    /// A small chalk-colored dot -- the equivalent of MarkerRenderer's point
    /// sprite for secondary clips. Unlit so it reads consistently against
    /// any real-world lighting, same as the GL version's flat color.
    static func clipDot(color: UIColor = UIColor(red: 0.969, green: 0.953, blue: 0.910, alpha: 1),
                        radius: Float = 0.035) -> ModelEntity {
        let mesh = MeshResource.generateSphere(radius: radius)
        let material = UnlitMaterial(color: color)
        return ModelEntity(mesh: mesh, materials: [material])
    }

    /// The clay-colored active-placement dot used while placing a clip
    /// (PlaceStartClipRenderer's 60px marker).
    static func activeDot() -> ModelEntity {
        clipDot(color: UIColor(red: 0.757, green: 0.314, blue: 0.180, alpha: 1), radius: 0.05)
    }

    /// Dimmed already-placed-clip dot (PlaceStartClipRenderer's previous-clip
    /// markers).
    static func previousDot() -> ModelEntity {
        clipDot(color: UIColor(red: 0.9, green: 0.85, blue: 0.75, alpha: 0.85), radius: 0.03)
    }

    /// The grade label shown at the FIRST clip -- a port of
    /// GradeLabelRenderer: a rounded RUST-colored pill (#C1502E) with the
    /// grade in dark ink text and a small chalk dot near the right edge,
    /// rendered to a 320x160 bitmap and textured onto a 0.34m x 0.17m
    /// plane, billboarded toward the camera each frame by the hosting view.
    /// The hosting view also applies the same vertical nudge Android does
    /// (0.9 x label height along the camera's up vector) so the label sits
    /// just over the clip point rather than centered on it.
    static let gradeLabelWidthMeters: Float = 0.34
    static let gradeLabelHeightMeters: Float = 0.17
    static let gradeLabelVerticalNudge: Float = 0.17 * 0.9

    static func gradeLabel(text: String) -> ModelEntity {
        let labelText = text.isEmpty ? "\u{2022}" : text
        let image = renderPillImage(text: labelText)
        let plane = MeshResource.generatePlane(width: gradeLabelWidthMeters, height: gradeLabelHeightMeters)
        var material = UnlitMaterial()
        if let cg = image.cgImage,
           let texture = try? TextureResource.generate(from: cg, options: .init(semantic: .color)) {
            material.color = .init(texture: .init(texture))
            material.blending = .transparent(opacity: 1.0)
            material.opacityThreshold = 0.1
        }
        return ModelEntity(mesh: plane, materials: [material])
    }

    private static func renderPillImage(text: String) -> UIImage {
        // Same 320x160 canvas and layout as GradeLabelRenderer's bitmap.
        let width: CGFloat = 320, height: CGFloat = 160
        let dotRadius: CGFloat = 34
        let dotCenterX = width - dotRadius - 14
        let pillRect = CGRect(x: 6, y: 12, width: width - 20 - 6, height: height - 24)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { _ in
            let pill = UIBezierPath(roundedRect: pillRect, cornerRadius: (height - 24) / 2)
            UIColor(red: 0.757, green: 0.314, blue: 0.180, alpha: 1).setFill() // rust #C1502E
            pill.fill()

            let dot = UIBezierPath(ovalIn: CGRect(x: dotCenterX - dotRadius, y: height / 2 - dotRadius,
                                                    width: dotRadius * 2, height: dotRadius * 2))
            UIColor(red: 0.969, green: 0.953, blue: 0.910, alpha: 1).setFill() // chalk #F7F3E8
            dot.fill()

            let font = UIFont.systemFont(ofSize: 64, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor(red: 0.106, green: 0.137, blue: 0.114, alpha: 1) // ink #1B231D
            ]
            let textSize = (text as NSString).size(withAttributes: attrs)
            let textCenterX = (pillRect.minX + dotCenterX - dotRadius) / 2
            (text as NSString).draw(at: CGPoint(x: textCenterX - textSize.width / 2,
                                                  y: height / 2 - textSize.height / 2),
                                     withAttributes: attrs)
        }
    }
}
