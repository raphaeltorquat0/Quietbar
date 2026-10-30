import simd

/// Parâmetros do modelo. Unidades em metros, Y para cima, frente em +Z, concha direita em +X.
/// Proporções tiradas das vistas de referência do WH-1000XM5 (ver DECISIONS.md), sem logos.
public struct HeadphoneSpec: Hashable, Sendable {
    public enum Shape: Hashable, Sendable { case overEar, earbudsCase }
    public var shape = Shape.overEar
    // Concha oval (superelipse, mais larga embaixo)
    public var cupHalfHeight: Float = 0.065
    public var cupHalfWidth: Float = 0.050
    public var cupDepth: Float = 0.046
    /// Escala do contorno onde a lateral termina (afina da almofada até a placa).
    public var cupTopScale: Float = 0.78
    /// Forma do contorno: expoente da superelipse e alargamento da base.
    public var cupExponent: Float = 2.4
    public var cupEgg: Float = 0.12
    /// Perfil da lateral: quanto ela demora a afinar e quanto sobe logo no início.
    public var cupFalloff: Float = 2.2
    public var cupRise: Float = 0.75
    /// Descida do centro da placa em relação à concha, em metros (0 = centrada).
    public var plateDrop: Float = 0
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
    /// Largura do arco nas pontas; nil = igual à do topo.
    public var bandTipWidth: Float?
    /// Altura do arco em relação à meia largura.
    public var bandRise: Float = 1.45
    // Braço e haste
    public var hingeHeight: Float?              // altura da dobradiça; nil = na borda superior da carcaça
    public var sliderRise: Float = 0.036
    public var rodLength: Float = 0.014
    public var armWidth: Float = 0.011
    public var armDepth: Float = 0.017
    // Tesselação
    public var radialSegments = 72
    public var tubeSides = 24
    public var curveSegments = 64
    // Cores (sRGB 0…1)
    public var graphite: SIMD3<Float> = [0.17, 0.172, 0.18]
    public var metal: SIMD3<Float> = [0.55, 0.56, 0.58]
    public var fabric: SIMD3<Float> = [0.14, 0.142, 0.15]
    public var accent: SIMD3<Float> = [0.25, 0.55, 1.0]
    /// Fator sobre a rugosidade da carcaça: abaixo de 1, mais acetinada.
    public var shellRoughness: Float = 1

    public init() {}

    public static let `default` = HeadphoneSpec()

    /// Geometria só depende destes campos; cores ficam fora da chave de cache.
    var geometryKey: [Float] {
        [shape == .overEar ? 0 : 1, lightRing ? 1 : 0, cupHalfHeight, cupHalfWidth, cupDepth, cupTopScale, plateScale, ringChannelDepth, Float(ringSegments),
         cushionDepth, cushionInnerScale, cupTilt, headWidth, bandThickness, bandWidth,
         Float(radialSegments), Float(tubeSides), Float(curveSegments),
         cupExponent, cupEgg, cupFalloff, cupRise, plateDrop, bandTipWidth ?? -1, bandRise,
         hingeHeight ?? -1, sliderRise, rodLength, armWidth, armDepth]
    }

    /// Borda da placa: recuada para o anel, ou quase rente à lateral (costura de ~1 mm).
    var plateEdge: Float { lightRing ? plateScale : cupTopScale - 0.014 }

    func outline(_ side: Side) -> OvalOutline {
        // Concha direita: X local → −Y do mundo, então "baixo" é +X local; na esquerda, o contrário.
        OvalOutline(halfHeight: cupHalfHeight, halfWidth: cupHalfWidth, exponent: cupExponent, egg: cupEgg,
                    bottomSign: side == .right ? 1 : -1)
    }

    /// Modelo próprio do fone, pelo nome que ele informa. nil = sem modelo específico.
    public static func forModel(_ name: String) -> HeadphoneSpec? {
        if name.hasPrefix("WH-1000XM6") { return .wh1000xm6 }
        if name.hasPrefix("WF-LS900") || name == "LinkBuds S" { return .linkBudsS }
        return nil
    }

    /// LinkBuds S: estojo aberto com os dois fones; medidas em `EarbudsAssembly`.
    public static let linkBudsS: HeadphoneSpec = {
        var s = HeadphoneSpec()
        s.shape = .earbudsCase
        s.graphite = [0.66, 0.71, 0.78]
        s.fabric = [0.50, 0.54, 0.58]
        s.shellRoughness = 0.7
        return s
    }()

    /// WH-1000XM6: conchas em forma de ovo que afinam até uma placa pequena e baixa, arco que
    /// estreita nas pontas e braço fino que desce pela frente da concha.
    public static let wh1000xm6: HeadphoneSpec = {
        var s = HeadphoneSpec()
        s.cupHalfHeight = 0.0655
        s.cupHalfWidth = 0.0585
        s.cupDepth = 0.056
        s.cupTopScale = 0.60
        s.cupExponent = 2.15
        s.cupEgg = 0.19
        s.cupFalloff = 2.5
        s.cupRise = 0.62
        s.plateDrop = 0.0075
        s.cushionDepth = 0.029
        s.cushionInnerScale = 0.56
        s.cupTilt = 0.46
        s.headWidth = 0.082
        s.bandThickness = 0.0165
        s.bandWidth = 0.041
        s.bandTipWidth = 0.027
        s.bandRise = 1.22
        s.hingeHeight = 0.024
        s.sliderRise = 0.052
        s.rodLength = 0.008
        s.armWidth = 0.0095
        s.armDepth = 0.015
        s.shellRoughness = 0.62
        s.graphite = [0.105, 0.106, 0.112]
        s.fabric = [0.095, 0.096, 0.102]
        return s
    }()
}

public enum MaterialKind: Hashable, Sendable {
    case graphite, panel, metal, fabric, ring
}

public enum Side: CaseIterable, Sendable {
    case left, right
    var sign: Float { self == .left ? -1 : 1 }
    var suffix: String { self == .left ? "L" : "R" }
}
