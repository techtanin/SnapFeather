// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnapFeather",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SnapFeather", targets: ["SnapFeather"])
    ],
    targets: [
        .target(
            name: "CWebP",
            path: "Sources/CWebP",
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/opt/webp/include"])
            ]
        ),
        .executableTarget(
            name: "SnapFeather",
            dependencies: ["CWebP"],
            path: "Sources/SnapFeather",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("UniformTypeIdentifiers"),
                .unsafeFlags([
                    "/opt/homebrew/opt/webp/lib/libwebp.a",
                    "/opt/homebrew/opt/webp/lib/libsharpyuv.a"
                ])
            ]
        ),
        .testTarget(
            name: "SnapFeatherTests",
            dependencies: ["SnapFeather"],
            path: "Tests/SnapFeatherTests"
        )
    ]
)
