// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "s1-mini-engine",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "s1-mini-engine", targets: ["s1-mini-engine"])
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            path: "llama.xcframework"
        ),
        .executableTarget(
            name: "s1-mini-engine",
            dependencies: ["llama"],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        )
    ]
)
