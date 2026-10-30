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
        .testTarget(name: "MDRTransportTests", dependencies: ["MDRTransport"], path: "Packages/MDRTransport/Tests/MDRTransportTests"),
        .testTarget(name: "MDRSessionTests", dependencies: ["MDRSession"], path: "Packages/MDRSession/Tests/MDRSessionTests"),

        // Ferramenta de desenvolvimento e teste: nunca entra no binário de release (DECISIONS.md #83).
        .target(name: "MDRSimulator", dependencies: ["MDRKit"], path: "Packages/MDRSimulator/Sources/MDRSimulator"),
        .testTarget(name: "MDRSimulatorTests", dependencies: ["MDRSimulator", "MDRSession", "MDRKit"],
                    path: "Packages/MDRSimulator/Tests/MDRSimulatorTests"),

        .target(name: "HeadphoneModel", dependencies: ["MDRKit"], path: "Packages/HeadphoneModel/Sources/HeadphoneModel"),
        .testTarget(name: "HeadphoneModelTests", dependencies: ["HeadphoneModel", "MDRKit"], path: "Packages/HeadphoneModel/Tests/HeadphoneModelTests"),

        .executableTarget(
            name: "mdr-cli",
            dependencies: ["MDRKit", "MDRTransport", "MDRSession", "HeadphoneModel"],
            path: "Tools/mdr-cli"
        ),
    ]
)
