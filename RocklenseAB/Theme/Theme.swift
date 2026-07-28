import SwiftUI

/// Rocklense AB's palette, ported 1:1 from `colors.xml` (same hex values,
/// same names where there's a natural Swift equivalent) so the iOS app reads
/// as the same product, not a reskin. Deep forest/clay theme: warm paper
/// backgrounds, a near-black "void" for dark surfaces (the AR camera scrim,
/// status bar), clay/rust as the primary action color, sage/pine as the
/// secondary.
enum RLColor {
    static let limestone = Color(hex: 0xECE4D3)   // paper background
    static let dusk = Color(hex: 0x14211B)        // void -- dark surfaces
    static let dusk2 = Color(hex: 0x1C2B23)        // void2
    static let ink = Color(hex: 0x1E2A22)          // primary text
    static let rust = Color(hex: 0xD9482C)         // clay -- primary action color
    static let pine = Color(hex: 0x8B9A73)         // sage -- secondary
    static let chalk = Color(hex: 0xF5F0E4)        // paperCard -- cards on dark, AR markers

    static let clayDark = Color(hex: 0xB93A22)
    static let sageDark = Color(hex: 0x6E7C58)
    static let foliage = Color(hex: 0x5E6B49)
    static let foliageDark = Color(hex: 0x4B5639)

    static let hairline = Color(hex: 0xF5F0E4, opacity: 0.14)   // borders on dark
    static let cream70 = Color(hex: 0xF5F0E4, opacity: 0.68)    // secondary text on dark
    static let cream50 = Color(hex: 0xF5F0E4, opacity: 0.50)    // muted text/icons on dark

    /// Inactive/unselected state color used in breadcrumb-style pickers
    /// (SelectClimbView) -- matches the hardcoded "#9A9186" in
    /// SelectClimbFragment.kt.
    static let inactiveText = Color(hex: 0x9A9186)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

/// Shared shape/spacing constants so cards, chips, and sheets look
/// consistent across every screen without re-deriving corner radii each time.
enum RLMetrics {
    static let cardCorner: CGFloat = 20
    static let chipCorner: CGFloat = 100
    static let sheetTopCorner: CGFloat = 28
    static let screenPadding: CGFloat = 20
}

/// A rounded "chalk pill" chip background, matching pill_chalk_background.xml
/// / chip_sage_bg.xml's rounded-pill treatment used for grade chips and filter chips.
struct RLChip: ViewModifier {
    var background: Color = RLColor.chalk
    var foreground: Color = RLColor.ink
    func body(content: Content) -> some View {
        content
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(background, in: Capsule())
    }
}

struct RLPrimaryButtonStyle: ButtonStyle {
    var background: Color = RLColor.rust
    var foreground: Color = RLColor.chalk
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(background.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 14))
    }
}

extension View {
    func rlChip(background: Color = RLColor.chalk, foreground: Color = RLColor.ink) -> some View {
        modifier(RLChip(background: background, foreground: foreground))
    }
}
