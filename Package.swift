// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DownloadTidy",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "DownloadTidy", targets: ["DownloadTidy"])],
    targets: [
        .target(name: "TidyCore"),
        .executableTarget(name: "DownloadTidy", dependencies: ["TidyCore"]),
        .testTarget(name: "TidyCoreTests", dependencies: ["TidyCore"])
    ],
    swiftLanguageModes: [.v5]
)
