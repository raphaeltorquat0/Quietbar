import Foundation
import simd

/// Contorno fechado no plano XZ local (superelipse, um pouco mais largo embaixo), usado para
/// "tornear" peças ovais: cada ponto do perfil (r, y) vira o contorno escalado por r na altura y.
public struct OvalOutline: Sendable {
    /// Meia altura (eixo X local) e meia largura (eixo Z local), em metros.
    public var halfHeight: Float
    public var halfWidth: Float
    public var exponent: Float = 2.4
    /// Alargamento da base: +12% de largura na parte de baixo.
    public var egg: Float = 0.12
    /// Lado do X local que é "baixo" no mundo (+1 ou -1); depende da orientação da concha.
    public var bottomSign: Float = 1

    func point(_ t: Float) -> SIMD2<Float> {
        func sp(_ v: Float) -> Float { (v < 0 ? -1 : 1) * pow(abs(v), 2 / exponent) }
        let c = cos(t), s = sin(t)
        let widen = 1 + egg * bottomSign * c
        return SIMD2(halfHeight * sp(c), halfWidth * sp(s) * widen)
    }

    /// Ponto e normal externa unitária do contorno.
    func sample(_ t: Float) -> (p: SIMD2<Float>, n: SIMD2<Float>) {
        let p = point(t), d = point(t + 1e-3) - point(t - 1e-3)
        var n = simd_normalize(SIMD2(d.y, -d.x))
        if simd_dot(n, p) < 0 { n = -n }
        return (p, n)
    }
}

extension Geometry {
    /// Normais 2D de um trecho de perfil (r, y): perpendicular à tangente, à direita do sentido do trecho.
    static func profileNormals(_ run: [SIMD2<Float>]) -> [SIMD2<Float>] {
        run.indices.map { i in
            let d = run[min(i + 1, run.count - 1)] - run[max(i - 1, 0)]
            return simd_normalize(SIMD2(d.y, -d.x))
        }
    }

    /// Torno oval: cada trecho suave do perfil (r adimensional, y em metros) percorre o contorno
    /// escalado por r. Trechos separados = arestas vivas. `t0…t1` limita o ângulo (segmentos do anel).
    /// Normal exata para superfícies homotéticas: n = (nr / (N·S))·N + ny·Y.
    /// `drop` desloca o centro de cada anel no X local, conforme a altura (lateral que desce até a placa).
    public static func ovalLathe(_ runs: [[SIMD2<Float>]], outline o: OvalOutline, segments: Int,
                                 from t0: Float = 0, to t1: Float = 2 * .pi,
                                 drop: (Float) -> Float = { _ in 0 }) -> MeshData {
        var m = MeshData()
        let samples = (0...segments).map { o.sample(t0 + (t1 - t0) * Float($0) / Float(segments)) }
        for run in runs {
            let normals = profileNormals(run)
            let first = UInt32(m.positions.count)
            for (i, pt) in run.enumerated() {
                for (c, s) in samples.enumerated() {
                    let k = normals[i].x / max(1e-6, simd_dot(s.n, s.p))
                    let n = SIMD3(k * s.n.x, normals[i].y, k * s.n.y)
                    _ = m.vertex(SIMD3(pt.x * s.p.x + drop(pt.y), pt.y, pt.x * s.p.y), simd_length(n) > 0 ? n : [0, 1, 0],
                                 SIMD2(Float(c) / Float(segments), Float(i) / Float(max(1, run.count - 1))))
                }
            }
            m.stitch(first: first, rows: run.count, cols: segments + 1)
        }
        return m
    }
}
