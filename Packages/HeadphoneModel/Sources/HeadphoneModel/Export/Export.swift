import AppKit
import MDRKit
import SceneKit

/// Ferramentas de verificação: USDZ para o Quick Look e PNG offscreen por estado.
@MainActor public enum HeadphoneExport {
    public struct State {
        public var mode: SoundMode = .noiseCanceling
        public var battery: Double = 0.62
        public var pose: CameraPose = .threeQuarter
        /// Instante da entrada a renderizar (nil = estado final, molas assentadas).
        public var entranceTime: Float?
        public init() {}
    }

    static func configuredRig(_ spec: HeadphoneSpec, _ st: State) -> HeadphoneRig {
        let rig = HeadphoneRig(spec: spec)
        rig.setSoundMode(st.mode)
        rig.setBattery(st.battery)
        rig.settle()
        if let t = st.entranceTime {
            rig.playEntrance()
            rig.stop()
            var e: Float = 0
            while e < t { rig.advance(1.0 / 120); e += 1.0 / 120 }
        }
        rig.stop()
        return rig
    }

    /// Exporta só o modelo (sem câmera, luz e sombra) no estado pedido.
    public static func exportUSDZ(to url: URL, spec: HeadphoneSpec = .default, state: State = State()) throws {
        let rig = configuredRig(spec, state)
        let sk = HeadphoneSceneKit(rig: rig)
        let out = SCNScene()
        out.rootNode.addChildNode(sk.model.clone())
        guard out.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    public static func snapshotSceneKit(to url: URL, size: CGSize = CGSize(width: 900, height: 900),
                                        spec: HeadphoneSpec = .default, state: State = State()) throws {
        try writePNG(snapshotImage(size: size, spec: spec, state: state), url)
    }

    /// Render offscreen do modelo (fundo transparente), usado também pelos previews do painel.
    public static func snapshotImage(size: CGSize, spec: HeadphoneSpec = .default, state: State = State()) -> NSImage {
        let rig = configuredRig(spec, state)
        let sk = HeadphoneSceneKit(rig: rig, pose: state.pose)
        let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        r.scene = sk.scene
        r.pointOfView = sk.camera
        return r.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }

    static func writePNG(_ image: NSImage, _ url: URL) throws {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        try png.write(to: url)
    }
}
