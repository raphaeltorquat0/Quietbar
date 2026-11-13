// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Quietbar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MDRKit", targets: ["MDRKit"]),
        .library(name: "MDRTransport", targets: ["MDRTransport"]),
        .library(name: "MDRSession", targets: ["MDRSession"]),
        .library(name: "HeadphoneModel", targets: ["HeadphoneModel"]),
        .library(name: "MDRSimulator", targets: ["MDRSimulator"]),
        .library(name: "QuietAudio", targets: ["QuietAudio"]),
        .library(name: "QuietAutomation", targets: ["QuietAutomation"]),
        .library(name: "QuietTelemetry", targets: ["QuietTelemetry"]),
        .executable(name: "mdr-cli", targets: ["mdr-cli"]),
    ],
    targets: [
        .target(name: "MDRKit", path: "Packages/MDRKit/Sources/MDRKit"),
        .testTarget(name: "MDRKitTests", dependencies: ["MDRKit"], path: "Packages/MDRKit/Tests/MDRKitTests"),

        .target(
            name: "MDRTransport",
            dependencies: ["MDRKit"],
            path: "Packages/MDRTransport/Sources/MDRTransport",
            linkerSettings: [.linkedFramework("IOBluetooth")]
        ),

        .target(name: "MDRSession", dependencies: ["MDRKit"], path: "Packages/MDRSession/Sources/MDRSession"),
        .testTarget(name: "MDRTransportTests", dependencies: ["MDRTransport", "MDRSession"], path: "Packages/MDRTransport/Tests/MDRTransportTests"),
        .testTarget(name: "MDRSessionTests", dependencies: ["MDRSession"], path: "Packages/MDRSession/Tests/MDRSessionTests"),

        // Ferramenta de desenvolvimento e teste: nunca entra no binário de release (DECISIONS.md #83).
        .target(name: "MDRSimulator", dependencies: ["MDRKit"], path: "Packages/MDRSimulator/Sources/MDRSimulator"),
        .testTarget(name: "MDRSimulatorTests", dependencies: ["MDRSimulator", "MDRSession", "MDRKit"],
                    path: "Packages/MDRSimulator/Tests/MDRSimulatorTests"),

        .target(name: "HeadphoneModel", dependencies: ["MDRKit"], path: "Packages/HeadphoneModel/Sources/HeadphoneModel"),
        .testTarget(name: "HeadphoneModelTests", dependencies: ["HeadphoneModel", "MDRKit"], path: "Packages/HeadphoneModel/Tests/HeadphoneModelTests"),

        // O que roda na thread de áudio fica em C: sem ARC nem runtime Swift no render (docs/AUDIO.md).
        .target(
            name: "CQuietAudio",
            path: "Packages/QuietAudio/Sources/CQuietAudio",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .target(name: "QuietAudio", dependencies: ["CQuietAudio"], path: "Packages/QuietAudio/Sources/QuietAudio"),
        .testTarget(name: "QuietAudioTests", dependencies: ["QuietAudio"], path: "Packages/QuietAudio/Tests/QuietAudioTests"),

        // Regras de contexto: ficam fora do protocolo (MDRKit) e testáveis sem o app (DECISIONS.md #117).
        .target(name: "QuietAutomation", dependencies: ["MDRKit"], path: "Packages/QuietAutomation/Sources/QuietAutomation"),
        .testTarget(name: "QuietAutomationTests", dependencies: ["QuietAutomation", "MDRKit"],
                    path: "Packages/QuietAutomation/Tests/QuietAutomationTests"),

        // Métricas opt-in: sem SDK de terceiros e testáveis sem o app (DECISIONS.md #142).
        .target(name: "QuietTelemetry", path: "Packages/QuietTelemetry/Sources/QuietTelemetry"),
        .testTarget(name: "QuietTelemetryTests", dependencies: ["QuietTelemetry", "MDRSimulator"], path: "Packages/QuietTelemetry/Tests/QuietTelemetryTests"),

        .executableTarget(
            name: "mdr-cli",
            dependencies: ["MDRKit", "MDRTransport", "MDRSession", "HeadphoneModel", "QuietAudio"],
            path: "Tools/mdr-cli"
        ),
    ]
)
