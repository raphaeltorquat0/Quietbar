import AppKit
import Foundation
import MDRKit
@testable import HeadphoneModel
import simd
import Testing

@Suite struct HeadphoneModelTests {
    let root = HeadphoneAssembly.build(.default)

    @Test func triangleBudget() {
        var withRing = HeadphoneSpec.default
        withRing.lightRing = true
        #expect(HeadphoneAssembly.build(withRing).triangleCount <= 30_000)
        #expect(root.triangleCount <= 30_000)
        #expect(root.triangleCount > 5_000) // não degenerou para quase nada
    }

    @Test func meshesAreWellFormed() {
        root.visit { node, _ in
            for pm in node.meshes {
                let m = pm.mesh
                #expect(m.normals.count == m.positions.count && m.uvs.count == m.positions.count, "\(node.name)")
                #expect(m.indices.count % 3 == 0)
                #expect(m.indices.allSatisfy { Int($0) < m.positions.count }, "índice fora do range em \(node.name)")
                #expect(m.normals.allSatisfy { abs(simd_length($0) - 1) < 1e-4 }, "normal não unitária em \(node.name)")
                #expect(m.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
            }
        }
    }

    /// Cada triângulo tem a face voltada para o mesmo lado das normais dos seus vértices.
    @Test func windingMatchesNormals() {
        root.visit { node, _ in
            for pm in node.meshes {
                let m = pm.mesh
                for t in stride(from: 0, to: m.indices.count, by: 3) {
                    let (a, b, c) = (Int(m.indices[t]), Int(m.indices[t + 1]), Int(m.indices[t + 2]))
                    let face = simd_cross(m.positions[b] - m.positions[a], m.positions[c] - m.positions[a])
                    #expect(simd_dot(face, m.normals[a] + m.normals[b] + m.normals[c]) >= 0, "\(node.name) tri \(t / 3)")
                }
            }
        }
    }

    @Test func hierarchy() {
        var spec = HeadphoneSpec.default
        spec.lightRing = true
        let root = HeadphoneAssembly.build(spec)
        for x in ["L", "R"] {
            let yoke = root.find("band")?.children.first { $0.name == "yoke\(x)" }
            let cup = yoke?.find("pivot\(x)")?.find("cup\(x)")
            #expect(cup?.children.map(\.name).sorted() == ["cushion\(x)", "ring\(x)"])
            #expect(cup?.find("ring\(x)")?.children.count == 48)
        }
    }

    @Test func modelIsCenteredAndSymmetric() {
        let b = root.bounds
        #expect(simd_length((b.min + b.max) / 2) < 1e-4)
        #expect(abs(b.max.x + b.min.x) < 1e-4)
    }

    @Test func generationIsFast() {
        _ = HeadphoneAssembly.build(.default) // aquece
        let t0 = Date()
        _ = HeadphoneAssembly.build(.default)
        let ms = Date().timeIntervalSince(t0) * 1000
        // Requisito: < 50 ms (release mede ~2 ms num M-series). Debug roda sem otimização (~50 ms).
        #if DEBUG
        #expect(ms < 200)
        #else
        #expect(ms < 50)
        #endif
    }

    @MainActor @Test func batteryLightsProportionalSegments() {
        final class Probe: RigTarget {
            var lit: [String: SIMD3<Float>] = [:]
            func setTransform(_ name: String, _ m: simd_float4x4) {}
            func setSegment(_ name: String, emission: SIMD3<Float>) { lit[name] = emission }
        }
        var spec = HeadphoneSpec.default
        spec.lightRing = true
        let rig = HeadphoneRig(spec: spec)
        let p = Probe()
        rig.target = p
        rig.setSoundMode(.noiseCanceling)
        rig.setBattery(0.5)
        rig.settle()
        rig.stop()
        let on = p.lit.filter { $0.key.hasPrefix("ringR.") && simd_length($0.value) > 0.01 }.count
        #expect(on == 24)
        rig.setSoundMode(.off)
        rig.settle()
        rig.stop()
        #expect(p.lit.values.allSatisfy { simd_length($0) < 0.01 })
    }
}

/// Snapshots só existem aqui: renderiza cada estado offscreen e confere que o modelo apareceu
/// e que o fundo ficou transparente.
@MainActor @Suite struct SnapshotTests {
    @Test(arguments: [SoundModeArg.nc, .ambient, .off])
    func rendersEachState(_ m: SoundModeArg) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "quietbar-\(m).png")
        var st = HeadphoneExport.State()
        st.mode = m.mode
        try HeadphoneExport.snapshotSceneKit(to: url, size: CGSize(width: 200, height: 200), state: st)
        let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
        let corner = try #require(rep.colorAt(x: 0, y: 0))
        #expect(corner.alphaComponent < 0.01, "fundo deveria ser transparente")
        // Amostra uma grade 20×20: o modelo tem que cobrir uma fração razoável da imagem.
        let opaque = (0..<400).filter { k in (rep.colorAt(x: 5 + (k % 20) * 10, y: 5 + (k / 20) * 10)?.alphaComponent ?? 0) > 0.5 }.count
        #expect(opaque > 40, "modelo não apareceu (\(opaque) de 400 amostras opacas)")
    }
}

enum SoundModeArg: String, CustomTestStringConvertible, Sendable {
    case nc, ambient, off
    var testDescription: String { rawValue }
    var mode: SoundMode { self == .nc ? .noiseCanceling : self == .ambient ? .ambient : .off }
}
