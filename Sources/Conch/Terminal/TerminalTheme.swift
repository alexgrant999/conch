import AppKit
import SwiftTerm

// Owner: core agent.

enum TerminalTheme {
    /// Monospaced font at the given size. SF Mono via NSFont.monospacedSystemFont.
    static func font(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Applies foreground, background, caret, selection and the 16-color ANSI palette for the view's effective appearance.
    static func apply(to view: TerminalView, dark: Bool) {
        let palette = dark ? Palette.dark : Palette.light
        let schemeChanged = !view.nativeBackgroundColor.matches(palette.background)
        view.installColors(palette.ansi.map(\.terminalColor))
        view.nativeForegroundColor = palette.foreground.color
        view.nativeBackgroundColor = palette.background.color
        view.caretColor = palette.caret.color
        view.caretTextColor = palette.background.color
        view.selectedTextBackgroundColor = palette.selection.color
        view.selectedTextForegroundColor = palette.selectionText.color
        // Programs that subscribed with CSI ? 2031 h re-query colors. Only tell them when light/dark flipped.
        view.updateColorScheme(dark ? .dark : .light, notify: schemeChanged)
    }

    /// Background color the container and window should use behind terminals, for the given appearance.
    static func background(dark: Bool) -> NSColor {
        (dark ? Palette.dark : Palette.light).background.color
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

private struct RGB {
    let red: UInt16
    let green: UInt16
    let blue: UInt16

    init(_ hex: UInt32) {
        red = UInt16((hex >> 16) & 0xFF)
        green = UInt16((hex >> 8) & 0xFF)
        blue = UInt16(hex & 0xFF)
    }

    var color: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    var terminalColor: SwiftTerm.Color {
        SwiftTerm.Color(red8: red, green8: green, blue8: blue)
    }
}

extension NSColor {
    /// Value equality for the plain sRGB colors the theme creates.
    fileprivate func matches(_ rgb: RGB) -> Bool {
        guard let srgb = usingColorSpace(.sRGB) else { return false }
        return Int((srgb.redComponent * 255).rounded()) == Int(rgb.red)
            && Int((srgb.greenComponent * 255).rounded()) == Int(rgb.green)
            && Int((srgb.blueComponent * 255).rounded()) == Int(rgb.blue)
    }
}

/// Neutral greys close to the macOS window colors, so the terminal reads as part of the window next to the sidebar.
/// ANSI text colors keep at least 4.5:1 contrast on the background, apart from black and white, whose job differs
/// per mode. The caret is Claude orange in both modes.
private struct Palette {
    let background: RGB
    let foreground: RGB
    let caret: RGB
    let selection: RGB
    let selectionText: RGB
    let ansi: [RGB]

    static let dark = Palette(
        background: RGB(0x1C1C1E),
        foreground: RGB(0xDCDCE0),
        caret: RGB(0xD97757),
        selection: RGB(0x3E4C66),
        selectionText: RGB(0xF2F2F5),
        ansi: [
            RGB(0x3B3C42), RGB(0xEF7A72), RGB(0x94C77F), RGB(0xE6C17A),
            RGB(0x72A7F0), RGB(0xC997E8), RGB(0x66C5C9), RGB(0xC9CAD0),
            RGB(0x83868F), RGB(0xFF968F), RGB(0xB3DE97), RGB(0xF3D592),
            RGB(0x97BFFF), RGB(0xDDB4F6), RGB(0x8EDDE0), RGB(0xF1F1F4),
        ])

    static let light = Palette(
        background: RGB(0xFBFBFC),
        foreground: RGB(0x1F1F24),
        caret: RGB(0xD97757),
        selection: RGB(0xBCD7FB),
        selectionText: RGB(0x1F1F24),
        ansi: [
            RGB(0x1F1F24), RGB(0xC4362C), RGB(0x2D7D34), RGB(0x946200),
            RGB(0x2259C4), RGB(0x9C3AB0), RGB(0x0E7782), RGB(0xB4B6BC),
            RGB(0x6B6E76), RGB(0xCB3D33), RGB(0x2E8337), RGB(0x9A6800),
            RGB(0x3470D8), RGB(0xA845BE), RGB(0x107E8C), RGB(0xD9DADF),
        ])
}
