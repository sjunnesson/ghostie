import AppKit

// MARK: - Theme tokens

enum Theme {

    static var windowBg: NSColor   { dyn(light: 0xECECEF, dark: 0x1C1C1E) }
    static var contentBg: NSColor  { dyn(light: 0xFFFFFF, dark: 0x1C1C1E) }
    static var cardBg: NSColor     { dyn(light: 0xFFFFFF, dark: 0x2C2C2E) }
    static var sidebarBg: NSColor  { dyn(light: 0xF6F6F9, dark: 0x242426) }
    static var cardBorder: NSColor {
        NSColor(name: nil) { ap in
            isDark(ap)
                ? NSColor(white: 1, alpha: 0.07)
                : NSColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.14)
        }
    }
    static var rowDivider: NSColor {
        NSColor(name: nil) { ap in
            isDark(ap)
                ? NSColor(white: 1, alpha: 0.07)
                : NSColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.12)
        }
    }
    static var chipBg: NSColor {
        NSColor(name: nil) { ap in
            isDark(ap)
                ? NSColor(white: 1, alpha: 0.06)
                : NSColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.08)
        }
    }
    static var selectedItem: NSColor {
        NSColor(name: nil) { ap in
            isDark(ap)
                ? NSColor(white: 1, alpha: 0.10)
                : NSColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.12)
        }
    }
    static var text: NSColor {
        NSColor(name: nil) { ap in
            isDark(ap)
                ? NSColor(white: 1, alpha: 0.92)
                : NSColor(white: 0, alpha: 0.86)
        }
    }
    static var text2: NSColor {
        NSColor(name: nil) { ap in
            isDark(ap)
                ? NSColor(red: 235/255, green: 235/255, blue: 245/255, alpha: 0.60)
                : NSColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.62)
        }
    }
    static var text3: NSColor {
        NSColor(name: nil) { ap in
            isDark(ap)
                ? NSColor(red: 235/255, green: 235/255, blue: 245/255, alpha: 0.35)
                : NSColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.35)
        }
    }
    static var accent: NSColor     { dyn(light: 0x5E5CE6, dark: 0x7D7AFF) }
    static var ok: NSColor         { dyn(light: 0x1F9D55, dark: 0x30D158) }
    static var warn: NSColor       { dyn(light: 0xB46300, dark: 0xFF9F0A) }
    static var danger: NSColor     { dyn(light: 0xC93B32, dark: 0xFF453A) }
    static var info: NSColor       { dyn(light: 0x0067CC, dark: 0x0A84FF) }

    static var okSoft: NSColor     { soft(.ok) }
    static var warnSoft: NSColor   { soft(.warn) }
    static var dangerSoft: NSColor { soft(.danger) }
    static var infoSoft: NSColor   { soft(.info) }
    static var accentSoft: NSColor { soft(.accent) }

    static var toolbarBg: NSColor      { sidebarBg }
    static var toolbarBorder: NSColor  { cardBorder }
    static var inputBorder: NSColor    { cardBorder }

    private static func dyn(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { ap in
            isDark(ap) ? rgb(dark) : rgb(light)
        }
    }
    /// True when `ap` is any dark appearance. A plain `ap.name == .darkAqua`
    /// check misses the *vibrant* variants (`.vibrantDark`) that AppKit hands
    /// to views inside an `NSVisualEffectView` — e.g. the whole settings
    /// sidebar, which is a vibrant `NSSplitViewItem` sidebar. `bestMatch`
    /// collapses every dark/vibrant-dark variant onto `.darkAqua`.
    private static func isDark(_ ap: NSAppearance) -> Bool {
        ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
    private enum SoftKind { case ok, warn, danger, info, accent }
    private static func soft(_ k: SoftKind) -> NSColor {
        NSColor(name: nil) { ap in
            let base: NSColor
            switch k {
            case .ok:     base = isDark(ap) ? rgb(0x30D158) : rgb(0x1F9D55)
            case .warn:   base = isDark(ap) ? rgb(0xFF9F0A) : rgb(0xB46300)
            case .danger: base = isDark(ap) ? rgb(0xFF453A) : rgb(0xC93B32)
            case .info:   base = isDark(ap) ? rgb(0x0A84FF) : rgb(0x0067CC)
            case .accent: base = isDark(ap) ? rgb(0x7D7AFF) : rgb(0x5E5CE6)
            }
            return base.withAlphaComponent(isDark(ap) ? 0.18 : 0.13)
        }
    }
}
