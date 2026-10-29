import AppKit
import RealityKit
import simd

/// Backend RealityKit (macOS 15+): usado pelo `RealityView` e pelo snapshot via `RealityRenderer`.
///
/// A IBL (≈ 0,7 s) e as malhas (≈ 70–180 ms) são geradas uma vez e guardadas; cada view clona um
/// protótipo pronto (`make(rig:)`). O app aquece o cache na abertura (`prewarm`), então o painel
/// abre na hora e o 3D aparece assim que o clone fica pronto.
@available(macOS 15, *)
@MainActor public final class HeadphoneRealityKit: RigTarget {
    /// Contém o modelo, a sombra de contato e a IBL; é isto que vai para a cena.
    public let container: Entity
    public let model: Entity
    private var entities: [String: Entity] = [:]
    private var segments: [String: ModelEntity] = [:]
    private var ringBase: PhysicallyBasedMaterial

    // MARK: Cache

    private static var environmentTask: Task<EnvironmentResource?, Never>?
    private static var prototypes: [[Float]: Entity] = [:]

    /// IBL gerada uma vez por processo.
    public static func environment() async -> EnvironmentResource? {
        if let t = environmentTask { return await t.value }
        let t = Task { @MainActor in try? await EnvironmentResource(equirectangular: StudioImages.environment) }
        environmentTask = t
        return await t.value
    }

    /// Deixa IBL e protótipo prontos (chamar na abertura do app).
    public static func prewarm(_ spec: HeadphoneSpec = .default) async {
        _ = try? await prototype(spec)
    }

    private static func prototype(_ spec: HeadphoneSpec) async throws -> Entity {
        if let p = prototypes[spec.geometryKey] { return p }
        let env = await environment()
        if let p = prototypes[spec.geometryKey] { return p } // outro chamador montou enquanto esperávamos
        let p = try buildPrototype(spec, env: env)
        prototypes[spec.geometryKey] = p
        return p
    }

    /// Clona o protótipo em cache e liga o rig a ele.
    public static func make(rig: HeadphoneRig) async throws -> HeadphoneRealityKit {
        let proto = try await prototype(rig.spec)
        return HeadphoneRealityKit(container: proto.clone(recursive: true), rig: rig)
    }

    private init(container: Entity, rig: HeadphoneRig) {
        self.container = container
        ringBase = Self.material(.ring, rig.spec)
        // O clone ainda aponta a IBL para o protótipo; religa cada malha ao próprio container.
        let receiver = ImageBasedLightReceiverComponent(imageBasedLight: container)
        var entities: [String: Entity] = [:]
        var segments: [String: ModelEntity] = [:]
        func walk(_ e: Entity) {
            if !e.name.isEmpty { entities[e.name] = e }
            if let m = e as? ModelEntity, e.name != "shadow" {
                m.components.set(receiver)
                if let parent = e.parent, parent.name.hasPrefix("ring"), parent.name.contains(".") { segments[parent.name] = m }
            }
            for c in e.children { walk(c) }
        }
        walk(container)
        model = entities["root"] ?? container
        self.entities = entities
        self.segments = segments
        rig.target = self
    }

    private static func buildPrototype(_ spec: HeadphoneSpec, env: EnvironmentResource?) throws -> Entity {
        let container = Entity()
        let tree = HeadphoneAssembly.make(spec)
        if let env { container.components.set(ImageBasedLightComponent(source: .single(env), intensityExponent: 1.6)) }

        var materials: [MaterialKind: PhysicallyBasedMaterial] = [:]
        func build(_ p: PartNode) throws -> Entity {
            let e = Entity()
            e.name = p.name
            e.transform = Transform(matrix: p.transform)
            for pm in p.meshes {
                let mat = materials[pm.material] ?? material(pm.material, spec)
                materials[pm.material] = mat
                e.addChild(ModelEntity(mesh: try mesh(pm.mesh), materials: [mat]))
            }
            for c in p.children { e.addChild(try build(c)) }
            return e
        }
        container.addChild(try build(tree))
        // Luz principal (como a do SceneKit): sem ela o preto fosco perde todo o volume.
        let key = DirectionalLight()
        key.light.intensity = 2600
        key.look(at: .zero, from: [-0.8, 0.6, 0.7], relativeTo: nil)
        container.addChild(key)

        let b = tree.bounds
        let size = b.max - b.min
        var shadowMat = UnlitMaterial()
        shadowMat.color = .init(tint: .white, texture: .init(try TextureResource(image: StudioImages.contactShadow,
                                                                                  options: .init(semantic: .color))))
        shadowMat.blending = .transparent(opacity: .init(floatLiteral: 1))
        let shadow = ModelEntity(mesh: .generatePlane(width: size.x * 1.25, depth: size.x * 0.65), materials: [shadowMat])
        shadow.position = [0, -size.y / 2 - 0.004, 0]
        shadow.name = "shadow"
        container.addChild(shadow)
        return container
    }

    func setTransform(_ name: String, _ m: simd_float4x4) { entities[name]?.transform = Transform(matrix: m) }

    func setSegment(_ name: String, emission e: SIMD3<Float>) {
        var m = ringBase
        let peak = max(e.x, e.y, e.z)
        if peak > 0 {
            let c = e / peak
            m.emissiveColor = .init(color: NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1))
            m.emissiveIntensity = peak * 2.2
        }
        segments[name]?.model?.materials = [m]
    }

    /// Câmera equivalente à do SceneKit para a mesma pose.
    public static func camera(_ pose: CameraPose) -> PerspectiveCamera {
        let cam = PerspectiveCamera()
        cam.camera.fieldOfViewInDegrees = pose.fov
        cam.camera.near = 0.01
        cam.look(at: .zero, from: pose.position, relativeTo: nil)
        return cam
    }

    static func mesh(_ m: MeshData) throws -> MeshResource {
        var d = MeshDescriptor()
        d.positions = MeshBuffers.Positions(m.positions)
        d.normals = MeshBuffers.Normals(m.normals)
        d.textureCoordinates = MeshBuffers.TextureCoordinates(m.uvs)
        d.primitives = .triangles(m.indices)
        return try MeshResource.generate(from: [d])
    }

    static func material(_ k: MaterialKind, _ s: HeadphoneSpec) -> PhysicallyBasedMaterial {
        let p = MaterialParams(k, s)
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: NSColor(srgbRed: CGFloat(p.color.x), green: CGFloat(p.color.y), blue: CGFloat(p.color.z), alpha: 1))
        m.metallic = .init(floatLiteral: p.metallic)
        m.roughness = .init(floatLiteral: p.roughness)
        return m
    }
}

@available(macOS 15, *)
extension HeadphoneExport {
    /// Renderiza com o `RealityRenderer` offscreen — o mesmo backend do `RealityView` do app.
    public static func snapshotRealityKit(to url: URL, size: CGSize = CGSize(width: 900, height: 900),
                                          spec: HeadphoneSpec = .default, state: State = State()) async throws {
        let rig = configuredRig(spec, state)
        let rk = try await HeadphoneRealityKit.make(rig: rig)
        let renderer = try RealityRenderer()
        let cam = HeadphoneRealityKit.camera(state.pose)
        renderer.entities.append(rk.container)
        renderer.entities.append(cam)
        renderer.activeCamera = cam
        renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 0))
        renderer.lighting.resource = await HeadphoneRealityKit.environment()

        let w = Int(size.width), h = Int(size.height)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared // ponytail: Apple Silicon; GPU dedicada (Intel) precisaria de .managed + blit
        guard let tex = MTLCreateSystemDefaultDevice()?.makeTexture(descriptor: desc) else {
            throw CocoaError(.featureUnsupported)
        }
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: tex))
        // Dois quadros: o primeiro aquece a IBL/materiais.
        for _ in 0..<2 {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                do {
                    try renderer.updateAndRender(deltaTime: 1.0 / 60, cameraOutput: output, onComplete: { _ in c.resume() })
                } catch { c.resume() }
            }
        }

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        try writePNG(NSImage(cgImage: ctx.makeImage()!, size: size), url)
    }
}
