import simd

/// Parâmetros PBR de cada material; os dois backends traduzem daqui.
struct MaterialParams {
    var color: SIMD3<Float>
    var metallic: Float
    var roughness: Float

    init(_ k: MaterialKind, _ s: HeadphoneSpec) {
        switch k {
        case .graphite: (color, metallic, roughness) = (s.graphite, 0, 0.55 * s.shellRoughness)
        case .panel: (color, metallic, roughness) = (s.graphite, 0, 0.42 * s.shellRoughness)
        case .metal: (color, metallic, roughness) = (s.metal, 1, 0.28)
        case .fabric: (color, metallic, roughness) = (s.fabric, 0, 0.70)
        case .ring: (color, metallic, roughness) = ([0.02, 0.021, 0.024], 0, 0.25)
        }
    }
}
