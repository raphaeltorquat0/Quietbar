import AppKit
import Observation

struct SavedEqualizer: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var clearBass: Int
    var bands: [Int]
}

/// Preferências locais do app (não ficam no fone).
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    @ObservationIgnored private let d = UserDefaults.standard

    var idleReleaseSeconds: Int { didSet { d.set(idleReleaseSeconds, forKey: "idleReleaseSeconds") } }
    var lowBatteryAlert: Bool { didSet { d.set(lowBatteryAlert, forKey: "lowBatteryAlert") } }
    var lowBatteryThreshold: Int { didSet { d.set(lowBatteryThreshold, forKey: "lowBatteryThreshold") } }
    var batteryCheckMinutes: Int { didSet { d.set(batteryCheckMinutes, forKey: "batteryCheckMinutes") } }
    var logTraffic: Bool { didSet { d.set(logTraffic, forKey: "logTraffic") } }
    var savedEqualizers: [SavedEqualizer] { didSet { save(savedEqualizers, "savedEqualizers") } }
    var developerMode: Bool { didSet { d.set(developerMode, forKey: "developerMode") } }
    /// Nomes dados pelo usuário aos presets personalizados (chave = ID do preset em decimal).
    var presetNames: [String: String] { didSet { save(presetNames, "presetNames") } }
    /// Anel de luz no modelo 3D (bateria e modo). O XM5 real não tem; padrão desligado.
    var modelLightRing: Bool { didSet { d.set(modelLightRing, forKey: "modelLightRing") } }
    var menuBarShowsPercent: Bool { didSet { d.set(menuBarShowsPercent, forKey: "menuBarShowsPercent") } }
    var popupEnabled: Bool { didSet { d.set(popupEnabled, forKey: "popupEnabled") } }
    var popupPosition: String { didSet { d.set(popupPosition, forKey: "popupPosition") } }
    var popupDuration: Double { didSet { d.set(popupDuration, forKey: "popupDuration") } }
    var popupUse3D: Bool { didSet { d.set(popupUse3D, forKey: "popupUse3D") } }
    /// Cor do anel do modelo 3D (sRGB). `nil` = cor de destaque do sistema.
    var ringColor: [Double]? { didSet { save(ringColor, "ringColor") } }

    var ringNSColor: NSColor {
        ringColor.map { NSColor(srgbRed: $0[0], green: $0[1], blue: $0[2], alpha: 1) } ?? .controlAccentColor
    }

    var ringAccent: SIMD3<Float> {
        let c = ringNSColor.usingColorSpace(.sRGB) ?? .systemBlue
        return SIMD3(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent))
    }

    private init() {
        d.register(defaults: ["idleReleaseSeconds": 15, "lowBatteryAlert": true, "lowBatteryThreshold": 20,
                              "batteryCheckMinutes": 15, "logTraffic": false, "popupEnabled": true,
                              "popupPosition": "topRight", "popupDuration": 5.0, "popupUse3D": true, "menuBarShowsPercent": false, "developerMode": false, "modelLightRing": false])
        idleReleaseSeconds = d.integer(forKey: "idleReleaseSeconds")
        lowBatteryAlert = d.bool(forKey: "lowBatteryAlert")
        lowBatteryThreshold = d.integer(forKey: "lowBatteryThreshold")
        batteryCheckMinutes = d.integer(forKey: "batteryCheckMinutes")
        logTraffic = d.bool(forKey: "logTraffic")
        savedEqualizers = Self.load("savedEqualizers") ?? []
        presetNames = Self.load("presetNames") ?? [:]
        menuBarShowsPercent = d.bool(forKey: "menuBarShowsPercent")
        developerMode = d.bool(forKey: "developerMode")
        modelLightRing = d.bool(forKey: "modelLightRing")
        popupEnabled = d.bool(forKey: "popupEnabled")
        popupPosition = d.string(forKey: "popupPosition") ?? "topRight"
        popupDuration = d.double(forKey: "popupDuration")
        popupUse3D = d.bool(forKey: "popupUse3D")
        ringColor = Self.load("ringColor")
    }

    func save<T: Encodable>(_ v: T, _ key: String) { d.set(try? JSONEncoder().encode(v), forKey: key) }

    static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
