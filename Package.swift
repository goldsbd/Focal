// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Focal",
    platforms: [.macOS("27.0")],   // the macOS every release is tested on; lower only after testing an older one
    dependencies: [
        // GitHub-flavoured Markdown (tables, task lists, strikethrough, autolinks): the reference C parser.
        .package(url: "https://github.com/apple/swift-cmark", exact: "0.9.0"),
    ],
    targets: [
        .target(name: "FocalKit", dependencies: [
            .product(name: "cmark-gfm", package: "swift-cmark"),
            .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
        ]),
        .executableTarget(name: "Focal", dependencies: ["FocalKit"]),
        .testTarget(name: "FocalKitTests", dependencies: ["FocalKit"]),
    ]
)
