import CoreGraphics
import Foundation
import MDRKit
import simd

@MainActor public protocol HeadphoneAnimating {
    func playEntrance()                      // conchas giram de 90° para 0°, arco assenta com spring
    func setBattery(_ level: Double)         // anel acende 0…1 em 48 segmentos
    func setSoundMode(_ mode: SoundMode)     // NC: destaque; Ambiente: branco quente pulsando; Off: apagado
    func setIdleRotation(_ on: Bool)         // rotação lenta em Y
    func tilt(towards point: CGPoint)        // ponto normalizado: (0,0) centro, (±1, ±1) bordas da view
}

/// O que um renderizador precisa expor para o rig animar.
@MainActor protocol RigTarget: AnyObject {
    func setTransform(_ name: String, _ m: simd_float4x4)
    func setSegment(_ name: String, emission: SIMD3<Float>)
}

struct Spring {
    var value: Float
    var velocity: Float = 0
    var target: Float
    var stiffness: Float
    var damping: Float

    init(_ v: Float, stiffness: Float, damping: Float? = nil) {
        value = v; target = v; self.stiffness = stiffness
        self.damping = damping ?? 2 * stiffness.squareRoot() // crítico por padrão
    }

    mutating func step(_ dt: Float) {
        let n = max(1, Int((dt * 240).rounded(.up)))
        let h = dt / Float(n)
        for _ in 0..<n {
            velocity += (-stiffness * (value - target) - damping * velocity) * h
            value += velocity * h
        }
    }

    var settled: Bool { abs(value - target) < 1e-4 && abs(velocity) < 1e-3 }
    mutating func snap() { value = target; velocity = 0 }
}

/// Estado animável do modelo. Um timer de 60 Hz avança as molas e empurra transformações e
/// emissão dos segmentos para o renderizador (RealityKit ou SceneKit).
@MainActor public final class HeadphoneRig: HeadphoneAnimating {
    public var spec: HeadphoneSpec { didSet { lastEmission.removeAll(); apply() } }
    public var reduceMotion = false
    /// Substitui a transformação base do "root" (modelo .usdz do usuário, já normalizado).
    var rootBase: simd_float4x4? { didSet { apply() } }

    weak var target: RigTarget? { didSet { lastEmission.removeAll(); apply() } }

    private let base: [String: simd_float4x4]
    private var swivel = Spring(0, stiffness: 90, damping: 9)
    private var bandDrop = Spring(0, stiffness: 170, damping: 8)
    private var battery = Spring(0, stiffness: 18)
    private var fade = Spring(1, stiffness: 40)
    private var modeMix = Spring(1, stiffness: 50)
    private var tiltYaw = Spring(0, stiffness: 40)
    private var tiltPitch = Spring(0, stiffness: 40)
    private var yaw: Float = 0
    private var idle = false
    private var mode: SoundMode?
    private var previousColor: SIMD3<Float> = .zero
    private var time: Float = 0
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var lastEmission: [String: SIMD3<Float>] = [:]

    public init(spec: HeadphoneSpec = .default) {
        self.spec = spec
        let root = HeadphoneAssembly.make(spec)
        var base: [String: simd_float4x4] = [:]
        for name in ["root", "band", "yokeL", "yokeR"] { base[name] = root.find(name)?.transform }
        self.base = base
    }

    // MARK: HeadphoneAnimating

    public func playEntrance() {
        battery.value = 0; battery.velocity = 0
        if reduceMotion {
            swivel.value = 0; bandDrop.value = 0
            fade.value = 0; fade.target = 1
            battery.snap()
        } else {
            swivel.value = .pi / 2; swivel.velocity = 0
            bandDrop.value = 0.012; bandDrop.velocity = 0
        }
        start()
    }

    public func setBattery(_ level: Double) {
        battery.target = Float(min(1, max(0, level)))
        start()
    }

    public func setSoundMode(_ m: SoundMode) {
        guard m != mode else { return }
        previousColor = color(for: mode)
        mode = m
        modeMix.value = 0; modeMix.target = 1
        start()
    }

    public func setIdleRotation(_ on: Bool) {
        idle = on
        start()
    }

    public func tilt(towards p: CGPoint) {
        tiltYaw.target = Float(max(-1, min(1, p.x))) * 0.28
        tiltPitch.target = Float(max(-1, min(1, p.y))) * 0.16
        start()
    }

    /// Leva todas as molas ao alvo na hora (snapshots e testes).
    public func settle() {
        for k in [\HeadphoneRig.swivel, \.bandDrop, \.battery, \.fade, \.modeMix, \.tiltYaw, \.tiltPitch] {
            self[keyPath: k].snap()
        }
        apply()
    }

    // MARK: Laço

    func start() {
        apply()
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = Float(min(0.05, now - lastTick))
        lastTick = now
        advance(dt)
        if !busy { stop() }
    }

    /// Avança o tempo da animação em `dt` segundos.
    public func advance(_ dt: Float) {
        time += dt
        for k in [\HeadphoneRig.swivel, \.bandDrop, \.battery, \.fade, \.modeMix, \.tiltYaw, \.tiltPitch] {
            self[keyPath: k].step(dt)
        }
        if idle && !reduceMotion { yaw += dt * 0.35 }
        apply()
    }

    private var busy: Bool {
        (idle && !reduceMotion) || mode == .ambient
            || ![swivel, bandDrop, battery, fade, modeMix, tiltYaw, tiltPitch].allSatisfy(\.settled)
    }

    // MARK: Cores

    private func color(for m: SoundMode?) -> SIMD3<Float> {
        switch m {
        case .off: return .zero
        case .ambient:
            let pulse = 0.5 + 0.5 * sin(2 * .pi * time / 3.2)
            return SIMD3<Float>(1.0, 0.80, 0.58) * (0.45 + 0.75 * pulse)
        case .noiseCanceling, nil: return spec.accent * 1.6
        }
    }

    private func apply() {
        guard let target else { return }
        let motion = !reduceMotion
        let r = simd_float4x4.rotation(yaw + (motion ? tiltYaw.value : 0), [0, 1, 0])
            * .rotation(motion ? tiltPitch.value : 0, [1, 0, 0])
        target.setTransform("root", r * (rootBase ?? base["root", default: .identity]))
        target.setTransform("band", .translation([0, bandDrop.value, 0]) * base["band", default: .identity])
        for side in Side.allCases {
            let name = "yoke\(side.suffix)"
            target.setTransform(name, base[name, default: .identity] * .rotation(-side.sign * swivel.value, [0, 1, 0]))
        }

        let mix = min(1, max(0, modeMix.value))
        let c = simd_mix(previousColor, color(for: mode), SIMD3(repeating: mix)) * max(0, fade.value)
        let lit = battery.value * Float(spec.ringSegments)
        for side in Side.allCases where spec.lightRing {
            for i in 0..<spec.ringSegments {
                let e = c * min(1, max(0, lit - Float(i)))
                let name = HeadphoneAssembly.segmentName(side, i)
                if let last = lastEmission[name], simd_distance(last, e) < 0.004 { continue }
                lastEmission[name] = e
                target.setSegment(name, emission: e)
            }
        }
    }
}
