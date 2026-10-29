import AppKit
import SceneKit
import simd

/// Backend SceneKit: fallback do macOS 14, export USDZ e snapshots offscreen.
@MainActor public final class HeadphoneSceneKit: RigTarget {
    public let scene = SCNScene()
    public let model: SCNNode
    public let camera = SCNNode()
    private var nodes: [String: SCNNode] = [:]
    private var segmentMaterials: [String: SCNMaterial] = [:]

    public init(rig: HeadphoneRig, pose: CameraPose = .threeQuarter) {
        let tree = HeadphoneAssembly.make(rig.spec)
        var nodes: [String: SCNNode] = [:]
        var segs: [String: SCNMaterial] = [:]
        let spec = rig.spec
        func build(_ p: PartNode) -> SCNNode {
            let n = SCNNode()
            n.name = p.name
            n.simdTransform = p.transform
            for pm in p.meshes {
                let mat = Self.material(pm.material, spec)
                if pm.material == .ring { segs[p.name] = mat }
                n.addChildNode(SCNNode(geometry: Self.geometry(pm.mesh, mat)))
            }
            for c in p.children { n.addChildNode(build(c)) }
            nodes[p.name] = n
            return n
        }
        model = build(tree)
        self.nodes = nodes
        segmentMaterials = segs

        scene.rootNode.addChildNode(model)
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = StudioImages.environment
        scene.lightingEnvironment.intensity = 1.6

        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 450
        key.simdEulerAngles = [-0.6, -0.8, 0]
        scene.rootNode.addChildNode(key)

        let b = tree.bounds
        let size = b.max - b.min
        let shadow = SCNNode(geometry: SCNPlane(width: CGFloat(size.x * 1.25), height: CGFloat(size.x * 0.65)))
        let sm = shadow.geometry!.firstMaterial!
        sm.diffuse.contents = StudioImages.contactShadow
        sm.lightingModel = .constant
        sm.writesToDepthBuffer = false
        sm.blendMode = .alpha
        shadow.simdPosition = [0, -size.y / 2 - 0.004, 0]
        shadow.simdEulerAngles = [-.pi / 2, 0, 0]
        shadow.name = "shadow"
        scene.rootNode.addChildNode(shadow)

        let cam = SCNCamera()
        cam.fieldOfView = CGFloat(pose.fov)
        cam.zNear = 0.01
        cam.zFar = 10
        cam.wantsHDR = true
        cam.exposureOffset = 0.7
        cam.bloomIntensity = 0.6
        cam.bloomThreshold = 0.9
        cam.bloomBlurRadius = 6
        camera.camera = cam
        camera.simdPosition = pose.position
        camera.simdLook(at: .zero)
        scene.rootNode.addChildNode(camera)

        rig.target = self
    }

    func setTransform(_ name: String, _ m: simd_float4x4) { nodes[name]?.simdTransform = m }

    func setSegment(_ name: String, emission e: SIMD3<Float>) {
        segmentMaterials[name]?.emission.contents = NSColor(srgbRed: CGFloat(e.x), green: CGFloat(e.y), blue: CGFloat(e.z), alpha: 1)
    }

    // MARK: Conversão

    static func geometry(_ m: MeshData, _ material: SCNMaterial) -> SCNGeometry {
        let stride = MemoryLayout<SIMD3<Float>>.stride
        let pos = SCNGeometrySource(data: m.positions.withUnsafeBytes { Data($0) }, semantic: .vertex, vectorCount: m.positions.count,
                                    usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        let nor = SCNGeometrySource(data: m.normals.withUnsafeBytes { Data($0) }, semantic: .normal, vectorCount: m.normals.count,
                                    usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        let uv = SCNGeometrySource(data: m.uvs.withUnsafeBytes { Data($0) }, semantic: .texcoord, vectorCount: m.uvs.count,
                                   usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0,
                                   dataStride: MemoryLayout<SIMD2<Float>>.stride)
        let el = SCNGeometryElement(data: m.indices.withUnsafeBytes { Data($0) }, primitiveType: .triangles,
                                    primitiveCount: m.triangleCount, bytesPerIndex: 4)
        let g = SCNGeometry(sources: [pos, nor, uv], elements: [el])
        g.materials = [material]
        return g
    }

    static func material(_ k: MaterialKind, _ s: HeadphoneSpec) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        let p = MaterialParams(k, s)
        m.diffuse.contents = NSColor(srgbRed: CGFloat(p.color.x), green: CGFloat(p.color.y), blue: CGFloat(p.color.z), alpha: 1)
        m.metalness.contents = NSNumber(value: p.metallic)
        m.roughness.contents = NSNumber(value: p.roughness)
        m.emission.contents = NSColor.black
        return m
    }
}
