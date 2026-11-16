// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MSIControl",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MSIControl", targets: ["MSIControl"]),
        .executable(name: "MSIECHelper", targets: ["MSIECHelper"]),
        .executable(name: "MSIPowerService", targets: ["MSIPowerService"]),
        .executable(name: "MSISensorProbe", targets: ["MSISensorProbe"]),
        .executable(name: "MSICPUPowerProbe", targets: ["MSICPUPowerProbe"])
    ],
    targets: [
        .executableTarget(
            name: "MSIControl",
            dependencies: ["ECControl", "SystemSensors", "KeyboardLighting", "PowerServiceProtocol"],
            path: "Sources/ShenyingControl",
            exclude: ["Localizable.xcstrings"],
            resources: [.copy("Resources")]
        ),
        .target(name: "ECControl"),
        .target(name: "PowerServiceProtocol", dependencies: ["ECControl"]),
        .executableTarget(name: "MSIPowerService", dependencies: ["PowerServiceProtocol", "ECControl"]),
        .testTarget(name: "PowerServiceTests", dependencies: ["PowerServiceProtocol", "ECControl"]),
        .executableTarget(name: "MSICPUPowerProbe", dependencies: ["ECControl"]),
        .testTarget(name: "CPUPowerTests", dependencies: ["ECControl"], path: "Tests/CPUPowerTests", exclude: ["CPUModelChecks.cpp", "PowerPolicyChecks.cpp"]),
        .target(name: "SystemSensors"),
        .target(name: "KeyboardLighting"),
        .executableTarget(name: "SystemSensorChecks", dependencies: ["SystemSensors"], path: "Tests/SystemSensorChecks"),
        .executableTarget(name: "MSISensorProbe", dependencies: ["SystemSensors", "ECControl"]),
        .executableTarget(name: "MSIECHelper", dependencies: ["ECControl"]),
    ]
)
