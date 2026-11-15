// swift-tools-version:5.9
// Note: build with ./build-app.sh (uses swiftc directly). This manifest is kept for opening in Xcode.
import PackageDescription

let package = Package(
    name: "OpenExplorer",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(name: "OpenExplorer", path: "Sources/OpenExplorer")
    ]
)
