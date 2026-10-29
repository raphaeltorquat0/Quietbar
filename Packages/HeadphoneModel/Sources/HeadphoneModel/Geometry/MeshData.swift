import simd

/// Malha indexada neutra (sem RealityKit/SceneKit): os dois renderizadores e os testes partem dela.
public struct MeshData: Sendable {
    public var positions: [SIMD3<Float>] = []
    public var normals: [SIMD3<Float>] = []
    public var uvs: [SIMD2<Float>] = []
    public var indices: [UInt32] = []

    public init() {}

    public var triangleCount: Int { indices.count / 3 }

    public mutating func append(_ o: MeshData) {
        let base = UInt32(positions.count)
        positions += o.positions
        normals += o.normals
        uvs += o.uvs
        indices += o.indices.map { $0 + base }
    }

    public func transformed(_ m: simd_float4x4) -> MeshData {
        let n = simd_float3x3(m.columns.0.xyz, m.columns.1.xyz, m.columns.2.xyz).inverse.transpose
        var r = self
        r.positions = positions.map { (m * SIMD4($0, 1)).xyz }
        r.normals = normals.map { simd_normalize(n * $0) }
        return r
    }

    mutating func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float>) -> UInt32 {
        positions.append(p)
        normals.append(simd_normalize(n))
        uvs.append(uv)
        return UInt32(positions.count - 1)
    }

    /// Triângulo com a ordem corrigida para ficar anti-horário visto do lado da normal.
    /// Assim nenhum gerador precisa acertar o winding na mão.
    mutating func triangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        let pa = positions[Int(a)], pb = positions[Int(b)], pc = positions[Int(c)]
        let face = simd_cross(pb - pa, pc - pa)
        guard simd_length_squared(face) > 1e-18 else { return } // degenerado
        let avg = normals[Int(a)] + normals[Int(b)] + normals[Int(c)]
        indices += simd_dot(face, avg) >= 0 ? [a, b, c] : [a, c, b]
    }

    /// Costura uma grade `rows × cols` de vértices já emitidos a partir de `first`.
    mutating func stitch(first: UInt32, rows: Int, cols: Int) {
        for r in 0..<(rows - 1) {
            for c in 0..<(cols - 1) {
                let i = first + UInt32(r * cols + c)
                let j = i + UInt32(cols)
                triangle(i, j, i + 1)
                triangle(i + 1, j, j + 1)
            }
        }
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

// MARK: - Transformações

public extension simd_float4x4 {
    static let identity = matrix_identity_float4x4

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    static func rotation(_ angle: Float, _ axis: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: angle, axis: simd_normalize(axis)))
    }
}
