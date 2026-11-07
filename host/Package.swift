// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DualScreenHost",
    platforms: [.macOS("13.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(
            name: "CGVirtualDisplayShim",
            path: "Sources/CGVirtualDisplayShim",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .target(
            name: "VTEncoderShim",
            path: "Sources/VTEncoderShim",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
        .executableTarget(
            name: "DualScreenHost",
            dependencies: ["CGVirtualDisplayShim", "VTEncoderShim", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/DualScreenHost",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Network"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path"]),
            ]
        )
    ]
)
