// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CodexDial", platforms: [.macOS(.v14)], products: [.executable(name: "CodexDial", targets: ["CodexDial"])], targets: [.executableTarget(name: "CodexDial", path: "Sources")])
