// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "coding-agent-proxy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "coding-agent-proxy", targets: ["RegionProxy"])],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0")],
    targets: [
        .target(name: "RegionProxyCore", dependencies: ["Yams"]),
        .executableTarget(name: "RegionProxy", dependencies: ["RegionProxyCore"]),
        .testTarget(name: "RegionProxyCoreTests", dependencies: ["RegionProxyCore"])
    ]
)
