import Foundation
import simd

/// Estojo aberto com os dois fones assentados: `root > case{lid}, budL, budR`.
/// O rig gira só o `root`; as peças de um fone de arco não existem aqui.
enum EarbudsAssembly {
    private static let halfLength: Float = 0.031, halfDepth: Float = 0.0205
    private static let baseHeight: Float = 0.0265, lidHeight: Float = 0.0135
    private static let lidAngle: Float = 1.78

    private static var plan: OvalOutline {
        OvalOutline(halfHeight: halfLength, halfWidth: halfDepth, exponent: 3.1, egg: 0)
    }

    static func build(_ s: HeadphoneSpec) -> PartNode {
        let lid = PartNode(name: "lid", transform: .translation([0, baseHeight, -halfDepth]) * .rotation(-lidAngle, [1, 0, 0]),
                           meshes: [PartMesh(mesh: lidMesh(s), material: .graphite)])
        let box = PartNode(name: "case", transform: .identity, meshes: [PartMesh(mesh: baseMesh(s), material: .graphite)], children: [lid])
        var root = PartNode(name: "root", transform: .identity,
                            children: [box, bud(s, .left, at: [-0.0145, 0.0255, 0.0015], yaw: 0.35, roll: 0.25),
                                       bud(s, .right, at: [0.0145, 0.0285, 0.001], yaw: -0.55, roll: -0.95)])
        // Aumenta para a câmera, que enquadra um fone de arco.
        let b = root.bounds
        root.transform = simd_float4x4(diagonal: [3.1, 3.1, 3.1, 1]) * .translation(-(b.min + b.max) / 2)
        return root
    }

    /// Base: fundo macio, parede reta, borda fina e o vão onde os fones assentam.
    private static func baseMesh(_ s: HeadphoneSpec) -> MeshData {
        let corner = (0...10).map { i -> SIMD2<Float> in
            let a = Float(i) / 10 * .pi / 2
            return [0.80 + 0.20 * sin(a), 0.009 * (1 - cos(a))]
        }
        return Geometry.ovalLathe([
            [[0, 0]] + corner + [[1, 0.018], [1, baseHeight - 0.0012], [0.985, baseHeight]],
            [[0.985, baseHeight], [0.93, baseHeight]],
            [[0.93, baseHeight], [0.93, 0.013]],
            [[0.93, 0.013], [0, 0.013]],
        ], outline: plan, segments: s.radialSegments)
    }

    /// Tampa: casca fina, do lado de fora arredondada e por dentro rebaixada.
    private static func lidMesh(_ s: HeadphoneSpec) -> MeshData {
        let dome = (0...10).map { i -> SIMD2<Float> in
            let a = Float(i) / 10 * .pi / 2
            return [0.78 + 0.22 * cos(a), 0.006 + (lidHeight - 0.006) * sin(a)]
        }
        return Geometry.ovalLathe([
            [[0, 0.004], [0.93, 0.004]],
            [[0.93, 0.004], [0.93, 0]],
            [[0.93, 0], [1, 0]],
            [[1, 0]] + dome + [[0, lidHeight]],
        ], outline: plan, segments: s.radialSegments).transformed(.translation([0, 0, halfDepth]))
    }

    /// Fone: corpo liso em forma de feijão e ponta de silicone saindo pela lateral.
    private static func bud(_ s: HeadphoneSpec, _ side: Side, at p: SIMD3<Float>, yaw: Float, roll: Float) -> PartNode {
        let h: Float = 0.0098
        let body = (0...24).map { i -> SIMD2<Float> in
            let a = Float(i) / 24 * .pi
            return [sin(a), -h * cos(a)]
        }
        let shell = OvalOutline(halfHeight: 0.0112, halfWidth: 0.0098, exponent: 2.25, egg: 0.14, bottomSign: side.sign)
        let tipOutline = OvalOutline(halfHeight: 0.0052, halfWidth: 0.0052, exponent: 2, egg: 0)
        // Ponta em cogumelo: a saia macia e o bocal rebaixado no centro.
        let tipRun: [SIMD2<Float>] = (0...14).map { i in
            let a = Float(i) / 14 * .pi * 0.86
            return [0.42 + 0.58 * sin(a), 0.0034 - 0.0034 * cos(a)]
        } + [[0.34, 0.0062], [0.30, 0.0050], [0, 0.0050]]
        let tip = Geometry.ovalLathe([tipRun], outline: tipOutline, segments: s.radialSegments / 2)
            .transformed(.translation([0, 0.0078, 0.0028]) * .rotation(-0.35, [1, 0, 0]))
        return PartNode(name: "bud\(side.suffix)",
                        transform: .translation(p) * .rotation(yaw, [0, 1, 0]) * .rotation(roll, [0, 0, 1]),
                        meshes: [PartMesh(mesh: Geometry.ovalLathe([body], outline: shell, segments: s.radialSegments), material: .graphite),
                                 PartMesh(mesh: tip, material: .fabric)])
    }
}
