import AppKit
import HeadphoneModel

/// `mdr-cli model --icon <pasta .appiconset>`: gera o ícone do app a partir do modelo 3D.
/// Grade de ícone do macOS: tela 1024, squircle de 824 centralizado, sombra própria.
@MainActor enum AppIconGenerator {
    static func write(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let master = render1024()
        var images: [[String: String]] = []
        for pt in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = pt * scale, name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
                try png(resize(master, px)).write(to: dir.appending(path: name))
                images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
            }
        }
        let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
        try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appending(path: "Contents.json"))
    }

    static func render1024() -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
        let shape = squircle(tile)

        // Sombra do ícone (abaixo, suave), como os ícones do sistema.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        NSColor.white.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Fundo: cinza-claro neutro de estúdio, um pouco mais claro em cima.
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(colors: [NSColor(white: 0.80, alpha: 1), NSColor(white: 0.93, alpha: 1), NSColor(white: 0.985, alpha: 1)],
                   atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: tile, angle: 90)
        // Brilho suave atrás do fone, sem cor.
        NSGradient(colors: [NSColor(white: 1, alpha: 0.85), NSColor(white: 1, alpha: 0)])!
            .draw(fromCenter: NSPoint(x: 512, y: 560), radius: 0, toCenter: NSPoint(x: 512, y: 560), radius: 380, options: [])

        var st = HeadphoneExport.State()
        st.battery = 0
        let model = HeadphoneExport.snapshotImage(size: CGSize(width: 1024, height: 1024), state: st)
        model.draw(in: NSRect(x: 80, y: 70, width: 864, height: 864), from: .zero, operation: .sourceOver, fraction: 1)

        // Fio de luz na borda superior para separar do fundo escuro do Dock.
        NSColor(white: 1, alpha: 0.6).setStroke()
        shape.lineWidth = 2
        shape.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Superelipse (n ≈ 5), próxima do contorno dos ícones da Apple.
    static func squircle(_ r: NSRect) -> NSBezierPath {
        let p = NSBezierPath(), n = 5.0, steps = 360
        for i in 0...steps {
            let t = Double(i) / Double(steps) * 2 * .pi
            let c = cos(t), s = sin(t)
            let x = r.midX + r.width / 2 * CGFloat((c < 0 ? -1 : 1) * pow(abs(c), 2 / n))
            let y = r.midY + r.height / 2 * CGFloat((s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
            i == 0 ? p.move(to: NSPoint(x: x, y: y)) : p.line(to: NSPoint(x: x, y: y))
        }
        p.close()
        return p
    }

    static func resize(_ src: NSBitmapImageRep, _ px: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }
}
