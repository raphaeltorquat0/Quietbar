import Foundation
import simd

public struct PartMesh: Sendable {
    public var mesh: MeshData
    public var material: MaterialKind
}

/// Nó da hierarquia neutra; RealityKit e SceneKit são construídos a partir dela.
public struct PartNode: Sendable {
    public var name: String
    public var transform: simd_float4x4
    public var meshes: [PartMesh] = []
    public var children: [PartNode] = []

    public func visit(_ parent: simd_float4x4 = .identity, _ body: (PartNode, simd_float4x4) -> Void) {
        let world = parent * transform
        body(self, world)
        for c in children { c.visit(world, body) }
    }

    public func find(_ name: String) -> PartNode? {
        if self.name == name { return self }
        for c in children { if let f = c.find(name) { return f } }
        return nil
    }

    public var triangleCount: Int {
        var n = 0
        visit { node, _ in n += node.meshes.reduce(0) { $0 + $1.mesh.triangleCount } }
        return n
    }

    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        visit { node, m in
            for pm in node.meshes { for p in pm.mesh.positions {
                let w = (m * SIMD4(p, 1)).xyz
                lo = simd_min(lo, w); hi = simd_max(hi, w)
            } }
        }
        return (lo, hi)
    }
}

/// Monta `root > band > yoke{L,R} > pivot{L,R} > cup{L,R} > ring{L,R} (48 segmentos), cushion{L,R}`.
public enum HeadphoneAssembly {
    nonisolated(unsafe) private static var cache: [[Float]: PartNode] = [:]
    private static let lock = NSLock()

    /// Gera uma vez por geometria e reaproveita (as cores não entram na chave).
    public static func make(_ s: HeadphoneSpec = .default) -> PartNode {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[s.geometryKey] { return c }
        let root = build(s)
        cache[s.geometryKey] = root
        return root
    }

    static func build(_ s: HeadphoneSpec) -> PartNode {
        if s.shape == .earbudsCase { return EarbudsAssembly.build(s) }
        let L = Layout(s: s)
        var band = PartNode(name: "band", transform: .identity, meshes: bandMeshes(s, L))
        band.children = Side.allCases.map { yoke(s, L, $0) }
        var root = PartNode(name: "root", transform: .identity, children: [band])
        let b = root.bounds
        root.transform = .translation(-(b.min + b.max) / 2)
        return root
    }

    /// Transformação da concha dentro do pivô: o +Y local (face) aponta para fora (±X).
    static func cupTransform(_ s: HeadphoneSpec, _ side: Side) -> simd_float4x4 {
        .translation([-side.sign * s.cupDepth / 2, 0, 0]) * .rotation(-side.sign * .pi / 2, [0, 0, 1])
    }

    private static func yoke(_ s: HeadphoneSpec, _ L: Layout, _ side: Side) -> PartNode {
        let sx = side.sign, x = side.suffix
        let mirror = SIMD3<Float>(sx, 1, 1)
        let slider = L.slider * mirror, hinge = L.hinge * mirror
        let toHinge = hinge - slider
        let toZ = simd_float4x4.rotation(.pi / 2, [1, 0, 0])

        // Haste deslizante (metal) com dois anéis, e o braço fino descendo até a dobradiça.
        var rod = Geometry.chamferedCylinder(radius: 0.0042, height: s.rodLength, chamfer: 0.0008)
            .transformed(.translation([0, s.rodLength / 2, 0]))
        for y: Float in [0.005, 0.009] where y < s.rodLength {
            rod.append(Geometry.chamferedCylinder(radius: 0.0049, height: 0.0016, chamfer: 0.0005).transformed(.translation([0, y, 0])))
        }
        let mid = toHinge * 0.5
        let armPath = (0...10).map { i -> SIMD3<Float> in
            let t = Float(i) / 10, u = 1 - t
            let p0: SIMD3<Float> = [0, 0.004, 0]
            return u * u * p0 + 2 * u * t * mid + t * t * toHinge
        }
        let arm = Parts.bar(armPath, up: [0, 0, 1], width: s.armWidth, depth: s.armDepth)

        // Pino curto escondido no fim do braço (o XM5 não mostra dobradiça aparente).
        let knuckle = Geometry.chamferedCylinder(radius: 0.0035, height: 0.012, chamfer: 0.001).transformed(toZ)

        let ring = PartNode(name: "ring\(x)", transform: .identity, children: (0..<(s.lightRing ? s.ringSegments : 0)).map { i in
            PartNode(name: segmentName(side, i), transform: .identity,
                     meshes: [PartMesh(mesh: Parts.ringSegment(s, index: i, side: side), material: .ring)])
        })
        let cushion = PartNode(name: "cushion\(x)", transform: .identity,
                               meshes: [PartMesh(mesh: Parts.cushion(s, side), material: .fabric)])
        let center = SIMD3<Float>(sx * L.cupCenterX, 0, 0)
        let cup = PartNode(name: "cup\(x)", transform: .translation(center - hinge) * cupTransform(s, side),
                           meshes: [PartMesh(mesh: Parts.cupShell(s, side), material: .graphite),
                                    PartMesh(mesh: Parts.plate(s, side), material: .panel)],
                           children: [ring, cushion])
        // A concha pende da dobradiça inclinada: base para dentro, como no fone de referência.
        let pivot = PartNode(name: "pivot\(x)", transform: .translation(toHinge) * .rotation(-sx * s.cupTilt, [0, 0, 1]),
                             meshes: [PartMesh(mesh: knuckle, material: .graphite)], children: [cup])
        return PartNode(name: "yoke\(x)", transform: .translation(slider),
                        meshes: [PartMesh(mesh: rod, material: .metal), PartMesh(mesh: arm, material: .graphite)],
                        children: [pivot])
    }

    public static func segmentName(_ side: Side, _ i: Int) -> String { "ring\(side.suffix).\(i)" }

    private static func bandMeshes(_ s: HeadphoneSpec, _ L: Layout) -> [PartMesh] {
        let e = L.bandEnd
        // Laterais verticais e topo arredondado (altura ≈ 1,1 × meia largura, como no XM5).
        let rise = s.bandRise * e.x
        let path = Geometry.cubicBezier([-e.x, e.y, e.z], [-e.x, e.y + rise, e.z],
                                        [e.x, e.y + rise, e.z], [e.x, e.y, e.z], samples: s.curveSegments)
        let section = Geometry.roundedRectSection(width: s.bandThickness, height: s.bandWidth,
                                                  radius: min(0.0055, s.bandThickness * 0.45))
        // Largura do topo às pontas, com transição suave (a seção é escalada só na largura).
        let tip = (s.bandTipWidth ?? s.bandWidth) / s.bandWidth
        let band = Geometry.sweep(path: path, up: [0, 0, 1], section: section, caps: true) { i in
            let u = abs(2 * Float(i) / Float(path.count - 1) - 1), w = min(1, u * 1.25)
            return tip + (1 - tip) * (1 - w * w * (3 - 2 * w))
        }
        // Luvas nas pontas: um pouco mais largas, cobrindo o fim do arco e o topo da haste.
        let n = s.curveSegments * 6 / 100
        var sleeves = MeshData()
        let sleeveSection = Geometry.roundedRectSection(width: s.bandThickness + 0.0025, height: (s.bandTipWidth ?? s.bandWidth) + 0.0015,
                                                        radius: min(0.009, (s.bandThickness + 0.0025) * 0.47))
        for part in [[path[0] - [0, 0.006, 0]] + Array(path[...n]),
                     Array(path[(path.count - 1 - n)...]) + [path[path.count - 1] - [0, 0.006, 0]]] {
            sleeves.append(Geometry.sweep(path: part, up: [0, 0, 1], section: sleeveSection, caps: true))
        }
        return [PartMesh(mesh: band, material: .fabric), PartMesh(mesh: sleeves, material: .graphite)]
    }
}
