import Foundation
import simd

/// Ponto de um perfil 2D (raio, altura) com a normal no mesmo plano.
public struct ProfilePoint: Sendable {
    public var r, y, nr, ny: Float
    public init(_ r: Float, _ y: Float, _ nr: Float, _ ny: Float) { (self.r, self.y, self.nr, self.ny) = (r, y, nr, ny) }
}

/// Ponto de uma seção transversal de sweep, com a normal no plano da seção.
public struct SectionPoint: Sendable {
    public var p, n: SIMD2<Float>
}

public enum Geometry {
    // MARK: Perfis

    /// Arco de raio `radius` em torno de `center`, ângulos em radianos; normal radial.
    public static func arc(_ center: SIMD2<Float>, _ radius: Float, _ t0: Float, _ t1: Float, steps: Int) -> [ProfilePoint] {
        (0...steps).map { i in
            let t = t0 + (t1 - t0) * Float(i) / Float(steps)
            return ProfilePoint(center.x + radius * cos(t), center.y + radius * sin(t), cos(t), sin(t))
        }
    }

    /// Segmento reto do perfil com normal constante (aresta viva nas pontas).
    public static func line(_ a: SIMD2<Float>, _ b: SIMD2<Float>, normal n: SIMD2<Float>) -> [ProfilePoint] {
        [ProfilePoint(a.x, a.y, n.x, n.y), ProfilePoint(b.x, b.y, n.x, n.y)]
    }

    // MARK: Torno (lathe)

    /// Revolve em torno de Y cada trecho suave do perfil. Trechos separados = arestas vivas.
    public static func lathe(_ runs: [[ProfilePoint]], segments: Int, from a0: Float = 0, to a1: Float = 2 * .pi) -> MeshData {
        var m = MeshData()
        for run in runs {
            let first = UInt32(m.positions.count)
            for (i, pt) in run.enumerated() {
                for c in 0...segments {
                    let a = a0 + (a1 - a0) * Float(c) / Float(segments)
                    _ = m.vertex(SIMD3(pt.r * cos(a), pt.y, pt.r * sin(a)),
                                 SIMD3(pt.nr * cos(a), pt.ny, pt.nr * sin(a)),
                                 SIMD2(Float(c) / Float(segments), Float(i) / Float(max(1, run.count - 1))))
                }
            }
            m.stitch(first: first, rows: run.count, cols: segments + 1)
        }
        return m
    }

    /// Cilindro em Y, centrado na origem, com as duas bordas arredondadas (`chamfer` = raio do filete).
    public static func chamferedCylinder(radius r: Float, height h: Float, chamfer c: Float, segments: Int = 32) -> MeshData {
        let run = line([0, -h / 2], [r - c, -h / 2], normal: [0, -1])
            + arc([r - c, -h / 2 + c], c, -.pi / 2, 0, steps: 3)
            + arc([r - c, h / 2 - c], c, 0, .pi / 2, steps: 3)
            + line([r - c, h / 2], [0, h / 2], normal: [0, 1])
        return lathe([run], segments: segments)
    }

    // MARK: Sweep

    /// Varre `section` ao longo de `path`. `up` fixa a orientação da seção (curvas planas não precisam
    /// de transporte paralelo). O eixo x da seção vai para `up × tangente`, o y para `up`.
    /// `widthScale` escala a seção no eixo y por ponto do caminho (arco mais estreito nas pontas).
    public static func sweep(path: [SIMD3<Float>], up: SIMD3<Float>, section: [SectionPoint], caps: Bool,
                             widthScale: (Int) -> Float = { _ in 1 }) -> MeshData {
        var m = MeshData()
        let ring = section + [section[0]]
        var frames: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [] // (N, B, T)
        for i in path.indices {
            let t = simd_normalize(path[min(i + 1, path.count - 1)] - path[max(i - 1, 0)])
            let b = simd_normalize(up - simd_dot(up, t) * t)
            frames.append((simd_cross(b, t), b, t))
        }
        let first = UInt32(m.positions.count)
        for (i, p) in path.enumerated() {
            let (n, b, _) = frames[i]
            for (j, s) in ring.enumerated() {
                _ = m.vertex(p + s.p.x * n + s.p.y * widthScale(i) * b, s.n.x * n + s.n.y * b,
                             SIMD2(Float(j) / Float(section.count), Float(i) / Float(path.count - 1)))
            }
        }
        m.stitch(first: first, rows: path.count, cols: ring.count)

        if caps {
            for (i, sign) in [(0, Float(-1)), (path.count - 1, Float(1))] {
                let (n, b, t) = frames[i]
                let c = m.vertex(path[i], sign * t, [0.5, 0.5])
                let w = widthScale(i)
                let rim = section.map { m.vertex(path[i] + $0.p.x * n + $0.p.y * w * b, sign * t, $0.p * 10 + 0.5) }
                for k in rim.indices { m.triangle(c, rim[k], rim[(k + 1) % rim.count]) }
            }
        }
        return m
    }

    public static func circleSection(radius: Float, sides: Int = 24) -> [SectionPoint] {
        (0..<sides).map { i in
            let t = 2 * Float.pi * Float(i) / Float(sides)
            let d = SIMD2(cos(t), sin(t))
            return SectionPoint(p: radius * d, n: d)
        }
    }

    public static func roundedRectSection(width w: Float, height h: Float, radius r: Float, cornerSteps: Int = 4) -> [SectionPoint] {
        let corners: [(SIMD2<Float>, Float)] = [([w / 2 - r, h / 2 - r], 0), ([-w / 2 + r, h / 2 - r], .pi / 2),
                                               ([-w / 2 + r, -h / 2 + r], .pi), ([w / 2 - r, -h / 2 + r], 3 * .pi / 2)]
        return corners.flatMap { c, a0 in
            (0...cornerSteps).map { i in
                let t = a0 + (.pi / 2) * Float(i) / Float(cornerSteps)
                let d = SIMD2(cos(t), sin(t))
                return SectionPoint(p: c + r * d, n: d)
            }
        }
    }

    // MARK: Curvas

    public static func cubicBezier(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>, samples: Int) -> [SIMD3<Float>] {
        (0...samples).map { i in
            let t = Float(i) / Float(samples), u = 1 - t
            return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
        }
    }
}
