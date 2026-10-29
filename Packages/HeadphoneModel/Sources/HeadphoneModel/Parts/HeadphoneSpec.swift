import simd

/// Parâmetros do modelo. Unidades em metros, Y para cima, frente em +Z, concha direita em +X.
/// Proporções tiradas das vistas de referência do WH-1000XM5 (ver DECISIONS.md), sem logos.
public struct HeadphoneSpec: Hashable, Sendable {
    // Concha oval (superelipse, mais larga embaixo)
    public var cupHalfHeight: Float = 0.065
    public var cupHalfWidth: Float = 0.050
    public var cupDepth: Float = 0.046
    /// Escala do contorno onde a lateral termina (afina da almofada até a placa).
    public var cupTopScale: Float = 0.78
    /// Escala da placa frontal plana (painel de toque).
    public var plateScale: Float = 0.68
    // Anel de luz opcional no vão entre a lateral e a placa (o XM5 real não tem; padrão desligado).
    // Sem ele, a placa cresce até quase a borda e o vão vira uma costura fina, como no fone.
    public var lightRing = false
    public var ringChannelDepth: Float = 0.0018
    public var ringSegments = 48
    // Almofada oval
    public var cushionDepth: Float = 0.024
    public var cushionInnerScale: Float = 0.55
    /// Inclinação das conchas (base para dentro, acompanhando a cabeça), em radianos.
    public var cupTilt: Float = 0.52
    // Arco
    public var headWidth: Float = 0.110        // distância entre as faces internas das almofadas
    public var bandThickness: Float = 0.019
    public var bandWidth: Float = 0.036
    // Tesselação
    public var radialSegments = 72
    public var tubeSides = 24
    public var curveSegments = 64
    // Cores (sRGB 0…1)
    public var graphite: SIMD3<Float> = [0.17, 0.172, 0.18]
    public var metal: SIMD3<Float> = [0.55, 0.56, 0.58]
    public var fabric: SIMD3<Float> = [0.14, 0.142, 0.15]
    public var accent: SIMD3<Float> = [0.25, 0.55, 1.0]

    public init() {}

    public static let `default` = HeadphoneSpec()

    /// Geometria só depende destes campos; cores ficam fora da chave de cache.
    var geometryKey: [Float] {
        [lightRing ? 1 : 0, cupHalfHeight, cupHalfWidth, cupDepth, cupTopScale, plateScale, ringChannelDepth, Float(ringSegments),
         cushionDepth, cushionInnerScale, cupTilt, headWidth, bandThickness, bandWidth,
         Float(radialSegments), Float(tubeSides), Float(curveSegments)]
    }

    /// Borda da placa: recuada para o anel, ou quase rente à lateral (costura de ~1 mm).
    var plateEdge: Float { lightRing ? plateScale : cupTopScale - 0.014 }

    func outline(_ side: Side) -> OvalOutline {
        // Concha direita: X local → −Y do mundo, então "baixo" é +X local; na esquerda, o contrário.
        OvalOutline(halfHeight: cupHalfHeight, halfWidth: cupHalfWidth, bottomSign: side == .right ? 1 : -1)
    }
}

public enum MaterialKind: Hashable, Sendable {
    case graphite, panel, metal, fabric, ring
}

public enum Side: CaseIterable, Sendable {
    case left, right
    var sign: Float { self == .left ? -1 : 1 }
    var suffix: String { self == .left ? "L" : "R" }
}
