import AppKit

/// The macOS "Icon & widget style" variants (System Settings › Appearance).
enum AppIconStyle: Equatable {
    case standard
    case dark
    case clear(dark: Bool)
    case tinted(NSColor, dark: Bool)

    var cacheKey: String {
        switch self {
        case .standard: "standard"
        case .dark: "dark"
        case .clear(let dark): "clear-\(dark)"
        case .tinted(let color, let dark):
            "tinted-\(dark)-\((color.usingColorSpace(.sRGB) ?? color).hexString)"
        }
    }
}

/// Draws the Open Explorer icon (folder + detail-list sheet + tree glyph) in any style.
/// Shared by the app (live Dock icon) and `scripts/make-icon.swift` (bundle .icns).
enum IconRenderer {
    private struct Palette {
        var background: [NSColor]
        var gloss: CGFloat
        var folderBack: [NSColor]
        var folderFront: [NSColor]
        var frontHighlight: NSColor
        var sheet: NSColor
        var sheetIcon: NSColor
        var sheetIconSecondary: NSColor
        var sheetLine: NSColor
        var glyph: NSColor
        var shadow: CGFloat
    }

    static func render(_ style: AppIconStyle, pixels: Int = 1024) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let scale = CGFloat(pixels) / 1024
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        draw(palette(for: style))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func image(_ style: AppIconStyle, pixels: Int = 1024) -> NSImage {
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.addRepresentation(render(style, pixels: pixels))
        return image
    }

    // MARK: Palettes

    private static func palette(for style: AppIconStyle) -> Palette {
        let amberBack = [hex(0xF2B347), hex(0xD98E22)]
        let amberFront = [hex(0xFFD978), hex(0xF6B532)]
        switch style {
        case .standard:
            return Palette(
                background: [hex(0x4F8DFF), hex(0x2350C8), hex(0x173A9C)], gloss: 0.18,
                folderBack: amberBack, folderFront: amberFront, frontHighlight: hex(0xFFF1C2, 0.9),
                sheet: .white, sheetIcon: hex(0x2F6BEA, 0.95), sheetIconSecondary: hex(0x2F6BEA, 0.55),
                sheetLine: hex(0x8A97AD, 0.75), glyph: hex(0xB8740F, 0.85), shadow: 0.30
            )
        case .dark:
            // Colourful artwork on a near-black tile, like Apple's dark icons.
            return Palette(
                background: [hex(0x3A3A3E), hex(0x232326), hex(0x111113)], gloss: 0.08,
                folderBack: amberBack, folderFront: amberFront, frontHighlight: hex(0xFFF1C2, 0.8),
                sheet: hex(0xF2F2F5), sheetIcon: hex(0x4F8DFF), sheetIconSecondary: hex(0x4F8DFF, 0.6),
                sheetLine: hex(0x8A8F99, 0.8), glyph: hex(0xB8740F, 0.85), shadow: 0.45
            )
        case .clear(let dark):
            // Frosted glass: translucent tile, monochrome white/grey artwork.
            let base: CGFloat = dark ? 0.0 : 1.0
            return Palette(
                background: [NSColor(white: base, alpha: dark ? 0.35 : 0.45), NSColor(white: base, alpha: dark ? 0.50 : 0.30)],
                gloss: 0.22,
                folderBack: [NSColor(white: 1, alpha: 0.55), NSColor(white: 1, alpha: 0.42)],
                folderFront: [NSColor(white: 1, alpha: 0.92), NSColor(white: 0.93, alpha: 0.82)],
                frontHighlight: NSColor(white: 1, alpha: 0.9),
                sheet: NSColor(white: 1, alpha: 0.97),
                sheetIcon: NSColor(white: 0.45, alpha: 0.9), sheetIconSecondary: NSColor(white: 0.55, alpha: 0.6),
                sheetLine: NSColor(white: 0.6, alpha: 0.7), glyph: NSColor(white: 0.45, alpha: 0.75), shadow: 0.25
            )
        case .tinted(let tintColor, let dark):
            // Monochrome artwork in the tint colour.
            let tint = tintColor.usingColorSpace(.sRGB) ?? tintColor
            func mix(_ other: NSColor, _ amount: CGFloat) -> NSColor { tint.blended(withFraction: amount, of: other) ?? tint }
            return Palette(
                background: dark ? [mix(.black, 0.72), mix(.black, 0.86)] : [mix(.white, 0.82), mix(.white, 0.70)],
                gloss: dark ? 0.06 : 0.25,
                folderBack: dark ? [mix(.black, 0.35), mix(.black, 0.45)] : [mix(.white, 0.25), mix(.white, 0.10)],
                folderFront: dark ? [mix(.white, 0.10), tint] : [mix(.white, 0.45), mix(.white, 0.30)],
                frontHighlight: mix(.white, 0.7),
                sheet: dark ? mix(.white, 0.85) : .white,
                sheetIcon: tint, sheetIconSecondary: tint.withAlphaComponent(0.55),
                sheetLine: mix(.black, 0.2).withAlphaComponent(0.45),
                glyph: dark ? mix(.black, 0.55) : mix(.black, 0.35), shadow: dark ? 0.45 : 0.22
            )
        }
    }

    // MARK: Drawing (1024×1024 canvas, macOS icon grid: 824pt tile)

    private static func draw(_ p: Palette) {
        let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
        withShadow(blur: 30, y: -14, alpha: p.shadow) {
            (p.background.first ?? .gray).setFill()
            tilePath.fill()
        }
        NSGraphicsContext.saveGraphicsState()
        tilePath.addClip()
        NSRect(x: 0, y: 0, width: 1024, height: 1024).fill(using: .clear)
        NSGraphicsContext.restoreGraphicsState()
        gradient(p.background).draw(in: tilePath, angle: -90)

        NSGraphicsContext.saveGraphicsState()
        tilePath.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(p.gloss), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Folder back with tab.
        let back = NSBezierPath()
        back.append(NSBezierPath(roundedRect: NSRect(x: 214, y: 268, width: 596, height: 418), xRadius: 42, yRadius: 42))
        back.append(NSBezierPath(roundedRect: NSRect(x: 214, y: 620, width: 250, height: 112), xRadius: 34, yRadius: 34))
        withShadow(blur: 24, y: -10, alpha: p.shadow) {
            (p.folderBack.last ?? .gray).setFill()
            back.fill()
        }
        gradient(p.folderBack).draw(in: back, angle: -90)

        // Sheet with a "detail list" (the right panel).
        let sheetRect = NSRect(x: 262, y: 360, width: 500, height: 330)
        let sheet = NSBezierPath(roundedRect: sheetRect, xRadius: 22, yRadius: 22)
        withShadow(blur: 10, y: -4, alpha: p.shadow * 0.6) {
            p.sheet.setFill()
            sheet.fill()
        }
        for i in 0..<4 {
            let y = sheetRect.maxY - 70 - CGFloat(i) * 52
            (i == 0 ? p.sheetIcon : p.sheetIconSecondary).setFill()
            NSBezierPath(roundedRect: NSRect(x: sheetRect.minX + 38, y: y, width: 34, height: 26), xRadius: 6, yRadius: 6).fill()
            p.sheetLine.setFill()
            let width: CGFloat = [300, 250, 330, 210][i]
            NSBezierPath(roundedRect: NSRect(x: sheetRect.minX + 90, y: y + 5, width: width, height: 16), xRadius: 8, yRadius: 8).fill()
        }

        // Folder front.
        let front = NSBezierPath(roundedRect: NSRect(x: 194, y: 236, width: 636, height: 330), xRadius: 48, yRadius: 48)
        withShadow(blur: 18, y: -8, alpha: p.shadow * 0.9) {
            (p.folderFront.last ?? .gray).setFill()
            front.fill()
        }
        gradient(p.folderFront).draw(in: front, angle: -90)
        p.frontHighlight.setFill()
        NSBezierPath(roundedRect: NSRect(x: 222, y: 536, width: 580, height: 10), xRadius: 5, yRadius: 5).fill()

        // Tree glyph (the left panel).
        p.glyph.setFill()
        let rows: [(x: CGFloat, y: CGFloat, w: CGFloat)] = [(270, 456, 190), (322, 400, 150), (322, 344, 170)]
        for row in rows {
            NSBezierPath(ovalIn: NSRect(x: row.x, y: row.y, width: 30, height: 30)).fill()
            NSBezierPath(roundedRect: NSRect(x: row.x + 46, y: row.y + 7, width: row.w, height: 16), xRadius: 8, yRadius: 8).fill()
        }
        let stem = NSBezierPath()
        stem.lineWidth = 9
        stem.lineCapStyle = .round
        stem.move(to: NSPoint(x: 285, y: 452))
        stem.line(to: NSPoint(x: 285, y: 359))
        stem.line(to: NSPoint(x: 316, y: 359))
        stem.move(to: NSPoint(x: 285, y: 415))
        stem.line(to: NSPoint(x: 316, y: 415))
        p.glyph.setStroke()
        stem.stroke()
    }

    // MARK: Helpers

    private static func gradient(_ colors: [NSColor]) -> NSGradient {
        NSGradient(colors: colors.count > 1 ? colors : colors + colors)!
    }

    private static func withShadow(blur: CGFloat, y: CGFloat, alpha: CGFloat, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = NSSize(width: 0, height: y)
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.set()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }
}

private extension NSColor {
    var hexString: String {
        String(format: "%02X%02X%02X", Int(redComponent * 255), Int(greenComponent * 255), Int(blueComponent * 255))
    }
}
