import AppKit

/// The Ollama mascot — a front-facing llama head and body silhouette with
/// two tall ears, a pair of eye cut-outs, and a small mouth. Drawn from
/// primitive shapes so it stays crisp at every size and tints correctly
/// via `NSImageView.contentTintColor` when rendered as a template image.
///
/// At 13–15 pt the eye and mouth holes shrink to a few pixels but still
/// telegraph "face" rather than "blob" — the same trick `GhostIcon` uses
/// for the menu-bar ghost (eyes-as-holes via `evenOdd` winding).
enum OllamaIcon {

    /// Combined path for the silhouette: outer body + ears, with eye and
    /// mouth shapes appended so `evenOdd` winding cuts them out.
    static func bodyPath(in r: NSRect) -> NSBezierPath {
        let p = NSBezierPath()
        let w = r.width, h = r.height
        let x0 = r.minX, y0 = r.minY
        func pt(_ nx: CGFloat, _ ny: CGFloat) -> NSPoint {
            NSPoint(x: x0 + nx * w, y: y0 + ny * h)
        }

        // ---- Main body + head as one bell-shaped silhouette ----
        // Traced counter-clockwise around the outside, with the two paws
        // at the bottom drawn as inward notches between the side curves.

        // Bottom-left corner of left paw
        p.move(to: pt(0.10, 0.00))
        // Up the outer side of the left paw, into the body curve
        p.line(to: pt(0.10, 0.18))
        // Body bulges left
        p.curve(to: pt(0.05, 0.50),
                controlPoint1: pt(0.05, 0.28),
                controlPoint2: pt(0.05, 0.40))
        // Up to the top of the head, rounding inward
        p.curve(to: pt(0.20, 0.78),
                controlPoint1: pt(0.05, 0.65),
                controlPoint2: pt(0.10, 0.74))
        // Across the top of the head (between the ears)
        p.curve(to: pt(0.80, 0.78),
                controlPoint1: pt(0.36, 0.86),
                controlPoint2: pt(0.64, 0.86))
        // Down the right side of the head
        p.curve(to: pt(0.95, 0.50),
                controlPoint1: pt(0.90, 0.74),
                controlPoint2: pt(0.95, 0.65))
        // Body bulges right
        p.curve(to: pt(0.90, 0.18),
                controlPoint1: pt(0.95, 0.40),
                controlPoint2: pt(0.95, 0.28))
        // Down to the right paw
        p.line(to: pt(0.90, 0.00))
        // Bottom of right paw, in to the gap between paws
        p.line(to: pt(0.62, 0.00))
        p.line(to: pt(0.62, 0.08))
        // Across the underbelly (small notch up between the paws)
        p.line(to: pt(0.38, 0.08))
        // Down the inner side of the left paw
        p.line(to: pt(0.38, 0.00))
        // Back to start
        p.close()

        // ---- Ears (two pointed shapes anchored on top of the head) ----
        // Drawn as separate sub-paths so each closes properly and they
        // visually sit "on top" of the head outline.
        let earL = NSBezierPath()
        earL.move(to: pt(0.18, 0.74))                        // base, on head
        earL.curve(to: pt(0.22, 1.00),                       // pointed tip
                   controlPoint1: pt(0.12, 0.82),
                   controlPoint2: pt(0.14, 0.96))
        earL.curve(to: pt(0.34, 0.78),                       // back down to head
                   controlPoint1: pt(0.30, 0.96),
                   controlPoint2: pt(0.32, 0.84))
        earL.close()
        p.append(earL)

        let earR = NSBezierPath()
        earR.move(to: pt(0.82, 0.74))
        earR.curve(to: pt(0.78, 1.00),
                   controlPoint1: pt(0.88, 0.82),
                   controlPoint2: pt(0.86, 0.96))
        earR.curve(to: pt(0.66, 0.78),
                   controlPoint1: pt(0.70, 0.96),
                   controlPoint2: pt(0.68, 0.84))
        earR.close()
        p.append(earR)

        // ---- Face details: two eye dots + a small mouth oval ----
        // Appended to the same combined path so `evenOdd` winding turns
        // them into holes, showing whatever's behind the icon through.
        let eyeSize: CGFloat = 0.10
        let eyeY: CGFloat = 0.50
        let eyeL = NSRect(x: x0 + (0.32 - eyeSize / 2) * w,
                          y: y0 + (eyeY - eyeSize / 2) * h,
                          width: eyeSize * w, height: eyeSize * h)
        let eyeR = NSRect(x: x0 + (0.68 - eyeSize / 2) * w,
                          y: y0 + (eyeY - eyeSize / 2) * h,
                          width: eyeSize * w, height: eyeSize * h)
        p.append(NSBezierPath(ovalIn: eyeL))
        p.append(NSBezierPath(ovalIn: eyeR))

        let mouthRect = NSRect(x: x0 + 0.36 * w, y: y0 + 0.30 * h,
                               width: 0.28 * w, height: 0.11 * h)
        p.append(NSBezierPath(ovalIn: mouthRect))

        p.windingRule = .evenOdd
        return p
    }

    /// Monochrome template image rendered from `bodyPath`. Used as a fallback
    /// when the bundled official PNG isn't available (e.g., a fresh SwiftPM
    /// checkout that hasn't fetched resources yet).
    static func drawnTemplateImage(pointSize: CGFloat = 13) -> NSImage {
        let s = pointSize
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        let r = NSRect(x: 0, y: 0, width: s, height: s)
        NSColor.black.setFill()
        bodyPath(in: r).fill()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    /// The official Ollama mascot PNG, loaded as a **template** image so the
    /// caller's `contentTintColor` (`.labelColor` etc.) controls its color —
    /// black on light backgrounds, white on dark. Resolved in this order:
    ///   1. `Bundle.main.resourceURL` — what `build-app.sh` populates inside
    ///      `Ghostie.app/Contents/Resources/ollama.png`. Production path.
    ///   2. The SwiftPM resource bundle (`ghostie_ghostie.bundle`) sitting
    ///      next to the executable — the `swift run` / `swift build` path.
    ///   3. The drawn silhouette — last-resort fallback so a stripped-down
    ///      checkout still has a recognizable icon.
    ///
    /// **Do not use the synthesized `Bundle.module` here.** Its generated
    /// accessor calls `fatalError` when the resource bundle can't be found,
    /// and `build-app.sh` does not copy `ghostie_ghostie.bundle` into the
    /// distributed `.app`. On any machine other than the one that produced
    /// the build, `Bundle.module` therefore crashes the whole process — see
    /// the Settings → Summary → Ollama crash this method previously caused.
    /// `Bundle(path:)` below returns `nil` instead of trapping.
    ///
    /// The image keeps its native aspect ratio; the caller is expected to
    /// pin one dimension (typically `heightAnchor`) and let `NSImageView`
    /// proportionally scale the other.
    static func templateImage() -> NSImage {
        // 1. Production .app: ollama.png copied straight into Contents/Resources.
        if let url = Bundle.main.resourceURL?.appendingPathComponent("ollama.png"),
           FileManager.default.fileExists(atPath: url.path),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            return img
        }
        // 2. `swift run` / `swift build`: the SwiftPM resource bundle is
        //    emitted next to the executable. Resolve it with `Bundle(path:)`
        //    (optional-returning, never traps) rather than `Bundle.module`.
        let sidecar = Bundle.main.bundleURL
            .appendingPathComponent("ghostie_ghostie.bundle")
        if let bundle = Bundle(path: sidecar.path),
           let url = bundle.url(forResource: "ollama", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            return img
        }
        // 3. Last resort: the drawn silhouette.
        return drawnTemplateImage(pointSize: 24)
    }
}
