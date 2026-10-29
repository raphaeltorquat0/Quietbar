import Foundation
import HeadphoneModel
import MDRKit

/// `mdr-cli model --icon <pasta.appiconset>` / `--export out.usdz` / `--snapshot out.png [--state nc|ambient|off] [--battery 0.62]
///  [--view three-quarter|front|side|top] [--renderer scenekit|realitykit] [--entrance <s>] [--size <px>]`
@MainActor func runModel(_ args: [String]) async throws {
    func value(_ flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
    var st = HeadphoneExport.State()
    if let s = value("--state") {
        switch s {
        case "nc": st.mode = .noiseCanceling
        case "ambient", "amb": st.mode = .ambient
        case "off": st.mode = .off
        default: throw CLIError("--state nc|ambient|off")
        }
    }
    if let b = value("--battery") {
        guard let v = Double(b), (0...1).contains(v) else { throw CLIError("--battery 0…1") }
        st.battery = v
    }
    if let v = value("--view") {
        let poses: [String: CameraPose] = ["three-quarter": .threeQuarter, "front": .front, "side": .side, "top": .top]
        guard let p = poses[v] else { throw CLIError("--view three-quarter|front|side|top") }
        st.pose = p
    }
    st.entranceTime = value("--entrance").flatMap(Float.init)
    let px = value("--size").flatMap(Double.init) ?? 900

    if let dir = value("--icon") {
        try AppIconGenerator.write(to: URL(fileURLWithPath: dir))
        print(dir)
    } else if let out = value("--export") {
        try HeadphoneExport.exportUSDZ(to: URL(fileURLWithPath: out), state: st)
        print(out)
    } else if let out = value("--snapshot") {
        let url = URL(fileURLWithPath: out), size = CGSize(width: px, height: px)
        if value("--renderer") == "realitykit" {
            guard #available(macOS 15, *) else { throw CLIError("RealityKit offscreen exige macOS 15") }
            try await HeadphoneExport.snapshotRealityKit(to: url, size: size, state: st)
        } else {
            try HeadphoneExport.snapshotSceneKit(to: url, size: size, state: st)
        }
        print(out)
    } else {
        let root = HeadphoneAssembly.make()
        print("triângulos: \(root.triangleCount)")
        throw CLIError("model --export <arquivo.usdz> | --snapshot <arquivo.png> [opções]")
    }
}
