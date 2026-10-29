import CoreGraphics
import Foundation

/// Imagens geradas em código: ambiente equiretangular para a IBL e a sombra de contato.
public enum StudioImages {
    /// Estúdio neutro: céu claro, horizonte médio, chão escuro, duas softboxes (chave e recorte).
    public static let environment: CGImage = {
        let w = 512, h = 256
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let gray = { (v: CGFloat) in CGColor(gray: v, alpha: 1) }
        // CoreGraphics tem origem embaixo: y alto = topo da imagem = céu.
        let sky = CGGradient(colorsSpace: nil, colors: [gray(0.10), gray(0.30), gray(0.55), gray(0.75)] as CFArray,
                             locations: [0, 0.45, 0.55, 1])!
        ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        func softbox(_ cx: CGFloat, _ cy: CGFloat, _ rw: CGFloat, _ rh: CGFloat, _ v: CGFloat) {
            let g = CGGradient(colorsSpace: nil, colors: [CGColor(gray: v, alpha: 1), CGColor(gray: v, alpha: 0)] as CFArray,
                               locations: [0.35, 1])!
            ctx.saveGState()
            ctx.translateBy(x: cx * CGFloat(w), y: cy * CGFloat(h))
            ctx.scaleBy(x: rw, y: rh)
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            ctx.restoreGState()
        }
        softbox(0.62, 0.78, 70, 34, 1.0)   // chave, frente-direita alta
        softbox(0.12, 0.70, 55, 40, 0.75)  // recorte, atrás-esquerda
        softbox(0.88, 0.70, 55, 40, 0.55)
        return ctx.makeImage()!
    }()

    /// Mancha radial preta com alfa para a sombra de contato.
    public static let contactShadow: CGImage = {
        let n = 256
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let g = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 0, alpha: 0.55), CGColor(gray: 0, alpha: 0.22), CGColor(gray: 0, alpha: 0)] as CFArray,
                           locations: [0, 0.45, 1])!
        let c = CGPoint(x: n / 2, y: n / 2)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(n) / 2, options: [])
        return ctx.makeImage()!
    }()
}

/// Enquadramento padrão: 3/4 pela esquerda, um pouco de baixo, com a placa esquerda de frente (foto clássica do XM5).
public struct CameraPose: Sendable {
    public var yaw: Float
    public var pitch: Float
    public var distance: Float
    public var fov: Float = 30

    public static let threeQuarter = CameraPose(yaw: -0.95, pitch: -0.18, distance: 0.68)
    // Vistas de engenharia: teleobjetiva (quase ortográfica), para comparar com desenhos de referência.
    public static let front = CameraPose(yaw: 0, pitch: 0, distance: 2.0, fov: 9.5)
    public static let side = CameraPose(yaw: .pi / 2, pitch: 0, distance: 2.0, fov: 9.5)
    public static let top = CameraPose(yaw: 0, pitch: 1.35, distance: 2.0, fov: 9.5)

    public var position: SIMD3<Float> {
        distance * SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
    }
}
