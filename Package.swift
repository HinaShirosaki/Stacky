// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Stacky",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Stacky", targets: ["AppUI"])],
    targets: [
        .target(name: "WindowKit", dependencies: ["SpacesKit"]),
        .target(name: "SpacesKit"),
        .target(name: "LaunchKit"),
        .target(name: "Store", dependencies: ["WindowKit", "SpacesKit", "LaunchKit"]),
        .executableTarget(name: "AppUI", dependencies: ["Store"]),
        .testTarget(name: "StackyTests", dependencies: ["Store"]),
    ]
)
