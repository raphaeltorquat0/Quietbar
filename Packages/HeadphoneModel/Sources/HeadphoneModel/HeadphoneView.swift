import MDRKit
import RealityKit
import SceneKit
import SwiftUI

/// Modelo 3D animado. `RealityView` no macOS 15+, `SCNView` no 14; mesmo rig nos dois.
/// Com `customModel` (um .usdz do usuário) mostra o arquivo dele, normalizado e girando devagar.
public struct HeadphoneView: View {
    var battery: Double?
    var mode: SoundMode?
    var accent: SIMD3<Float>
    var customModel: URL?
    var entranceID: Int
    var idleRotation: Bool
    var onFailure: () -> Void
    var reduceMotionOverride: Bool?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
    @State private var rig: HeadphoneRig

    /// `model`: mude a `id` da view junto com ele, porque o rig é criado uma vez.
    /// `entranceID`: mude o valor para tocar a entrada de novo. `onFailure`: o 3D não pôde ser montado (mostre o 2D).
    public init(battery: Double?, mode: SoundMode?, accent: SIMD3<Float> = HeadphoneSpec.default.accent,
                model: String? = nil, customModel: URL? = nil, entranceID: Int = 0, idleRotation: Bool = true, reduceMotion: Bool? = nil,
                lightRing: Bool = false, onFailure: @escaping () -> Void = {}) {
        self.reduceMotionOverride = reduceMotion
        // Nome que o fone informa; sem modelo próprio, vale a forma padrão.
        var spec = model.flatMap(HeadphoneSpec.forModel) ?? .default
        spec.lightRing = lightRing
        _rig = State(initialValue: HeadphoneRig(spec: spec))
        self.battery = battery
        self.mode = mode
        self.accent = accent
        self.customModel = customModel
        self.entranceID = entranceID
        self.idleRotation = idleRotation
        self.onFailure = onFailure
    }

    public var body: some View {
        GeometryReader { geo in
            renderer
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        rig.tilt(towards: CGPoint(x: p.x / geo.size.width * 2 - 1, y: p.y / geo.size.height * 2 - 1))
                    case .ended:
                        rig.tilt(towards: .zero)
                    }
                }
        }
        .onAppear(perform: sync)
        .onChange(of: entranceID) { rig.playEntrance() }
        .onChange(of: battery) { sync() }
        .onChange(of: mode) { sync() }
        .onChange(of: accent) { sync() }
        .onChange(of: reduceMotion) { sync() }
        .onDisappear { rig.stop() }
        .accessibilityElement()
        .accessibilityLabel("Fone de ouvido")
        .accessibilityValue(battery.map { "Bateria \(Int($0 * 100))%" } ?? "")
    }

    @ViewBuilder private var renderer: some View {
        if #available(macOS 15, *) {
            RealityHost(rig: rig, customModel: customModel, onFailure: onFailure)
        } else {
            SceneHost(rig: rig, customModel: customModel, onFailure: onFailure)
        }
    }

    private func sync() {
        rig.reduceMotion = reduceMotion
        if rig.spec.accent != accent { rig.spec.accent = accent }
        rig.setBattery(battery ?? 0)
        if let mode { rig.setSoundMode(mode) }
        rig.setIdleRotation(idleRotation)
        if !didPlayEntrance { rig.playEntrance() }
        didPlayEntrance = true
    }

    @State private var didPlayEntrance = false
}

// MARK: - Modelo importado

/// Carrega um .usdz do usuário e devolve a matriz que o centraliza e escala para caber no lugar do nosso.
enum CustomModel {
    static let maxBytes = 20 * 1024 * 1024

    static func isUsable(_ url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max
        return size <= maxBytes
    }

    static func normalization(min lo: SIMD3<Float>, max hi: SIMD3<Float>) -> simd_float4x4 {
        let ours = HeadphoneAssembly.make().bounds
        let target = simd_reduce_max(ours.max - ours.min)
        let size = simd_reduce_max(hi - lo)
        let k = size > 0 ? target / size : 1
        return simd_float4x4(diagonal: SIMD4(k, k, k, 1)) * .translation(-(lo + hi) / 2)
    }

    /// Só o "root" interessa: o modelo do usuário gira e inclina como um bloco.
    @MainActor final class RootTarget: RigTarget {
        let apply: (simd_float4x4) -> Void
        init(_ apply: @escaping (simd_float4x4) -> Void) { self.apply = apply }
        func setTransform(_ name: String, _ m: simd_float4x4) { if name == "root" { apply(m) } }
        func setSegment(_ name: String, emission: SIMD3<Float>) {}
    }
}

// MARK: - RealityKit (macOS 15+)

@available(macOS 15, *)
private struct RealityHost: View {
    let rig: HeadphoneRig
    let customModel: URL?
    let onFailure: () -> Void
    @State private var backend: HeadphoneRealityKit?
    @State private var custom: CustomModel.RootTarget?

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            content.add(HeadphoneRealityKit.camera(.threeQuarter))
            if let url = customModel, CustomModel.isUsable(url), let e = try? await Entity(contentsOf: url) {
                let b = e.visualBounds(relativeTo: nil)
                let holder = Entity()
                holder.addChild(e)
                let norm = CustomModel.normalization(min: b.min, max: b.max)
                let t = CustomModel.RootTarget { holder.transform = Transform(matrix: $0) }
                rig.rootBase = norm
                rig.target = t
                custom = t
                let env = await HeadphoneRealityKit.environment()
                if let env {
                    holder.components.set(ImageBasedLightComponent(source: .single(env), intensityExponent: 0.6))
                    e.components.set(ImageBasedLightReceiverComponent(imageBasedLight: holder))
                }
                content.add(holder)
                return
            }
            // .usdz inválido ou > 20 MB: cai no modelo procedural.
            rig.rootBase = nil
            guard let b = try? await HeadphoneRealityKit.make(rig: rig) else { return onFailure() }
            backend = b
            content.add(b.container)
        }
    }
}

// MARK: - SceneKit (macOS 14)

private struct SceneHost: NSViewRepresentable {
    let rig: HeadphoneRig
    let customModel: URL?
    let onFailure: () -> Void

    final class Coordinator {
        var backend: HeadphoneSceneKit?
        var custom: CustomModel.RootTarget?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling4X
        v.isPlaying = true // ponytail: redesenha a 60 Hz enquanto visível; pausar quando o rig parar se o custo aparecer
        rig.rootBase = nil
        let sk = HeadphoneSceneKit(rig: rig) // SceneKit não falha ao montar; onFailure fica para o RealityKit
        context.coordinator.backend = sk
        if let url = customModel {
            if CustomModel.isUsable(url), let s = try? SCNScene(url: url) {
                let holder = SCNNode()
                for c in s.rootNode.childNodes { holder.addChildNode(c) }
                let (lo, hi) = holder.boundingBox
                rig.rootBase = CustomModel.normalization(min: SIMD3(lo), max: SIMD3(hi))
                sk.model.isHidden = true
                sk.scene.rootNode.addChildNode(holder)
                let t = CustomModel.RootTarget { holder.simdTransform = $0 }
                rig.target = t
                context.coordinator.custom = t
            } // .usdz inválido ou > 20 MB: fica o modelo procedural.
        }
        v.scene = sk.scene
        v.pointOfView = sk.camera
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {}
}
