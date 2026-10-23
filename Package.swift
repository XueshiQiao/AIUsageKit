// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AIUsageKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AIUsageKit", targets: ["AIUsageKit"]),
        .executable(name: "aiusage", targets: ["aiusage"]),
    ],
    dependencies: [
        // 固定版本。CodexBarCore 的接口不承诺稳定，几乎每天发版；升级前看一眼 changelog，再手动改这里。
        // 只能按 commit 固定，不能写 `exact: "0.79.0"`：CodexBar 自己按 commit 依赖了 Vortex，
        // SwiftPM 不允许按版本号依赖一个「内含按 commit 依赖」的包。
        // 同理，用 AIUsageKit 的项目也只能按 path / branch / revision 依赖它。
        // b49d42eb = v0.79.0
        .package(url: "https://github.com/steipete/CodexBar.git", revision: "b49d42eb53bbf79785b344492d594760dd163eac"),
    ],
    targets: [
        .target(
            name: "AIUsageKit",
            dependencies: [.product(name: "CodexBarCore", package: "CodexBar")]),
        .executableTarget(
            name: "aiusage",
            dependencies: ["AIUsageKit"]),
        .testTarget(
            name: "AIUsageKitTests",
            dependencies: ["AIUsageKit", .product(name: "CodexBarCore", package: "CodexBar")]),
    ])
