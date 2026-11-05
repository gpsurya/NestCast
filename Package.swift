// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NestCast",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NestCastKit", targets: ["NestCastKit"]),
        .executable(name: "NestCast", targets: ["NestCast"])
    ],
    targets: [
        .target(
            name: "NestCastKit",
            path: "Sources/NestCastKit"
        ),
        .executableTarget(
            name: "NestCast",
            dependencies: ["NestCastKit"],
            path: "Sources/NestCast"
        ),
        .testTarget(
            name: "NestCastTests",
            dependencies: ["NestCastKit"],
            path: "Tests/NestCastTests",
            swiftSettings: [
                .unsafeFlags([
                    "-load-plugin-library",
                    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
                ])
            ]
        )
    ]
)
