// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MSIControl",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MSIControl", targets: ["MSIControl"]),
        .executable(name: "MSIECHelper", targets: ["MSIECHelper"]),
        .executable(name: "MSISensorProbe", targets: ["MSISensorProbe"])
    ],
    targets: [
        .executableTarget(
            name: "MSIControl",
            dependencies: ["ECControl", "SystemSensors", "KeyboardLighting"],
            path: "Sources/ShenyingControl",
            exclude: ["Localizable.xcstrings"],
            resources: [.copy("Resources")]
        ),
        .target(name: "ECControl"),
        .target(name: "SystemSensors"),
        .target(name: "KeyboardLighting"),
        .executableTarget(name: "SystemSensorChecks", dependencies: ["SystemSensors"], path: "Tests/SystemSensorChecks"),
        .executableTarget(name: "MSISensorProbe", dependencies: ["SystemSensors", "ECControl"]),
        .executableTarget(name: "MSIECHelper", dependencies: ["ECControl"]),
    ]
)
