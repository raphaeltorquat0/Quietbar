import Foundation
import simd

/// Geradores de cada peça, cada uma no próprio referencial local.
/// Concha, anel e almofada: torno oval com a face para +Y local e as costas em y = 0.
enum Parts {
    /// Carcaça: costas, lateral que afina até o vão do anel, e o vão. A placa é peça separada.
    static func cupShell(_ s: HeadphoneSpec, _ side: Side) -> MeshData {
        let d = s.cupDepth, g = s.lightRing ? s.ringChannelDepth : 0.001, ro = s.cupTopScale, rp = s.plateEdge
        let sideRun = (0...14).map { i -> SIMD2<Float> in
            let t = Float(i) / 14
            return [ro + (1 - ro) * (1 - pow(t, 2.2)), d * pow(t, 0.75)]
        }
        return Geometry.ovalLathe([
            [[0, 0], [1, 0]],                       // costas (escondidas pela almofada)
            sideRun,
            [[ro, d], [ro, d - g]],                 // parede externa do vão
            [[ro, d - g], [rp, d - g]],             // fundo do vão
        ], outline: s.outline(side), segments: s.radialSegments)
    }

    /// Placa frontal plana, levemente saliente.
    static func plate(_ s: HeadphoneSpec, _ side: Side) -> MeshData {
        let d = s.cupDepth, g = s.lightRing ? s.ringChannelDepth : 0.001, rp = s.plateEdge, top = d + 0.0003
        return Geometry.ovalLathe([[[rp, d - g], [rp, top]], [[rp, top], [rp * 0.5, top], [0, top]]],
                                  outline: s.outline(side), segments: s.radialSegments)
    }

    /// Um segmento do anel, dentro do vão entre a lateral e a placa.
    static func ringSegment(_ s: HeadphoneSpec, index i: Int, side: Side) -> MeshData {
        let step = 2 * Float.pi / Float(s.ringSegments), gap = step * 0.22
        // Índice 0 às 12h, crescendo no sentido horário visto de fora (ver `cupTransform`).
        let start: Float = (side == .right ? .pi : 0) + Float(i) * step
        let yb = s.cupDepth - s.ringChannelDepth, yt = s.cupDepth - s.ringChannelDepth * 0.35
        let ro = s.cupTopScale - 0.006, ri = s.plateScale + 0.006
        return Geometry.ovalLathe([[[ro, yb], [ro, yt]], [[ro, yt], [ri, yt]], [[ri, yt], [ri, yb]]],
                                  outline: s.outline(side), segments: 3, from: start + gap / 2, to: start + step - gap / 2)
    }

    /// Almofada oval atrás da carcaça (y < 0) + tela interna.
    static func cushion(_ s: HeadphoneSpec, _ side: Side) -> MeshData {
        let h = s.cushionDepth / 2, yc = cushionCenterY(s)
        let rc = (1 + s.cushionInnerScale) / 2, rr = (1 - s.cushionInnerScale) / 2
        // Seção em superelipse: laterais quase retas e cantos macios, como uma almofada de espuma.
        func sp(_ v: Float) -> Float { (v < 0 ? -1 : 1) * pow(abs(v), 2 / 3.2) }
        let ring = (0...40).map { k -> SIMD2<Float> in
            let t = 2 * Float.pi * Float(k) / 40
            return [rc + rr * sp(cos(t)), yc + h * sp(sin(t))]
        }
        return Geometry.ovalLathe([ring, [[0, -0.005], [s.cushionInnerScale + 0.02, -0.005]]],
                                  outline: s.outline(side), segments: s.radialSegments)
    }

    static func cushionCenterY(_ s: HeadphoneSpec) -> Float { -s.cushionDepth / 2 + 0.0015 }

    /// Ponto de contato com a cabeça, medido a partir das costas da concha.
    static func cushionReach(_ s: HeadphoneSpec) -> Float { s.cushionDepth - 0.0015 }

    /// Barra de seção retangular arredondada ao longo de um caminho.
    static func bar(_ path: [SIMD3<Float>], up: SIMD3<Float>, width: Float, depth: Float) -> MeshData {
        Geometry.sweep(path: path, up: up,
                       section: Geometry.roundedRectSection(width: width, height: depth, radius: min(width, depth) * 0.45),
                       caps: true)
    }
}

/// Medidas derivadas usadas pela montagem (mundo, concha direita; a esquerda espelha em X).
struct Layout {
    let s: HeadphoneSpec
    var cupCenterX: Float { s.headWidth / 2 + Parts.cushionReach(s) + s.cupDepth / 2 }
    var plateX: Float { cupCenterX + s.cupDepth / 2 }
    /// Dobradiça: na borda superior da carcaça, do lado da placa (o braço entra num entalhe e deixa
    /// a placa livre, como no XM5). Com a concha inclinada, ela aparece a ~1/3 da altura na vista frontal.
    var hinge: SIMD3<Float> { [plateX - 0.003, s.cupHalfHeight * s.cupTopScale * 0.98, -0.003] }
    /// Base da haste deslizante = origem do yoke; o braço desce para fora até a dobradiça.
    var slider: SIMD3<Float> { [plateX - 0.006, s.cupHalfHeight * s.cupTopScale + 0.036, -0.003] }
    var rodLength: Float { 0.014 }
    var bandEnd: SIMD3<Float> { slider + [0, rodLength, 0] }
}
