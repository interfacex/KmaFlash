// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "KmaFlash", platforms: [.macOS(.v14)], products: [.executable(name: "KmaFlash", targets: ["KmaFlash"]), .library(name: "FlashCore", targets: ["FlashCore"])], targets: [.target(name: "FlashCore", resources: [.process("Resources/personas.json"), .process("Resources/models.json")]), .executableTarget(name: "KmaFlash", dependencies: ["FlashCore"]), .executableTarget(name: "FlashCheck", dependencies: ["FlashCore"])])
