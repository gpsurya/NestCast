// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NestCast",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "NestCast", targets: ["NestCast"]),
        .executable(name: "NestCastTests", targets: ["NestCastTests"])
    ],
    targets: [
        .executableTarget(
            name: "NestCast",
            path: "Sources/NestCast"
        ),
        .executableTarget(
            name: "NestCastTests",
            path: "Tests/NestCastTests"
        )
    ]
)
