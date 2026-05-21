import AppKit

/// Draws the Ghostie mascot — a classic Pac-Man-style arcade ghost (rounded
/// dome, scalloped skirt, two eyes). Shared by the menu bar status item
/// (monochrome template, tinted by state) and the app icon (colored).
enum GhostIcon {

    /// Ghost body silhouette: dome top, straight sides, N-bump wavy skirt.
    static func bodyPath(in r: NSRect, feet: Int = 4) -> NSBezierPath {
        let p = NSBezierPath()
        let radius = r.width / 2
        let cx = r.midX
        let domeCenterY = r.maxY - radius
        let segW = r.width / CGFloat(feet)
        let skirtTop = r.minY + segW / 2          // bumps dip to r.minY

        p.move(to: NSPoint(x: r.minX, y: skirtTop))
        p.line(to: NSPoint(x: r.minX, y: domeCenterY))
        // Upper semicircle (left → top → right).
        p.appendArc(withCenter: NSPoint(x: cx, y: domeCenterY),
                    radius: radius, startAngle: 180, endAngle: 0, clockwise: true)
        p.line(to: NSPoint(x: r.maxX, y: skirtTop))
        // Scalloped skirt, right → left: downward-bulging half circles.
        for i in 0..<feet {
            let centerX = r.maxX - segW * (CGFloat(i) + 0.5)
            p.appendArc(withCenter: NSPoint(x: centerX, y: skirtTop),
                        radius: segW / 2, startAngle: 0, endAngle: 180, clockwise: true)
        }
        p.close()
        return p
    }

    /// (sclera, pupil) ellipse rects for one eye; mirrored for the other.
    static func eyeRects(in r: NSRect) -> (NSRect, NSRect, NSRect, NSRect) {
        let ew = r.width * 0.26, eh = r.width * 0.34
        let cy = r.midY + r.height * 0.12
        let dx = r.width * 0.17
        func sclera(_ centerX: CGFloat) -> NSRect {
            NSRect(x: centerX - ew/2, y: cy - eh/2, width: ew, height: eh)
        }
        let pw = ew * 0.52, ph = eh * 0.52
        func pupil(_ centerX: CGFloat) -> NSRect {
            NSRect(x: centerX - pw/2 + ew*0.16, y: cy - ph/2 - eh*0.10,
                   width: pw, height: ph)
        }
        let lx = r.midX - dx, rx = r.midX + dx
        return (sclera(lx), pupil(lx), sclera(rx), pupil(rx))
    }

    /// Monochrome template image for the menu bar (eyes are cut-out holes so
    /// the icon adapts to light/dark menus and the state tint color).
    static func menuBarImage(height: CGFloat = 18) -> NSImage {
        let size = NSSize(width: height * 0.82, height: height)
        let img = NSImage(size: size)
        img.lockFocus()
        let r = NSRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2)
        let path = bodyPath(in: r)
        let (sL, pL, sR, pR) = eyeRects(in: r)
        for e in [sL, pL, sR, pR] {           // eyes become holes via even-odd
            path.append(NSBezierPath(ovalIn: e))
        }
        path.windingRule = .evenOdd
        NSColor.black.setFill()
        path.fill()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    /// Colored app icon (rounded-rect background + gradient ghost + eyes).
    static func appIconImage(size: CGFloat = 1024) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()

        // Soft light rounded-rect background.
        let inset = size * 0.08
        let bg = NSRect(x: inset, y: inset, width: size - inset*2, height: size - inset*2)
        let bgPath = NSBezierPath(roundedRect: bg, xRadius: size*0.18, yRadius: size*0.18)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.93, green: 0.94, blue: 1.00, alpha: 1),
            NSColor(calibratedRed: 0.86, green: 0.88, blue: 0.99, alpha: 1)
        ])!.draw(in: bgPath, angle: -90)

        // Ghost body with an indigo→violet gradient.
        let gw = size * 0.56, gh = size * 0.60
        let gr = NSRect(x: (size - gw)/2, y: (size - gh)/2 + size*0.02,
                        width: gw, height: gh)
        let body = bodyPath(in: gr)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.95, alpha: 1),
            NSColor(calibratedRed: 0.52, green: 0.33, blue: 0.90, alpha: 1)
        ])!.draw(in: body, angle: -90)

        let (sL, pL, sR, pR) = eyeRects(in: gr)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: sL).fill()
        NSBezierPath(ovalIn: sR).fill()
        NSColor(calibratedRed: 0.15, green: 0.16, blue: 0.42, alpha: 1).setFill()
        NSBezierPath(ovalIn: pL).fill()
        NSBezierPath(ovalIn: pR).fill()

        img.unlockFocus()
        return img
    }

    /// Writes a PNG of the app icon (used by the `icon` CLI command).
    @discardableResult
    static func writeAppIconPNG(to path: String, size: CGFloat = 1024) -> Bool {
        let img = appIconImage(size: size)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
