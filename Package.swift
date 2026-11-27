// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CollabDock",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CollabDockCore",
            targets: ["CollabDockCore"]
        ),
        .executable(
            name: "CollabDock",
            targets: ["CollabDockApp"]
        )
    ],
    targets: [
        .target(
            name: "CollabDockCore",
            path: "Sources/CollabDockCore"
        ),
        .executableTarget(
            name: "CollabDockApp",
            dependencies: ["CollabDockCore"],
            path: "Sources/CollabDockApp"
        ),
        .testTarget(
            name: "CollabDockCoreTests",
            dependencies: ["CollabDockCore"],
            path: "Tests/CollabDockCoreTests"
        ),
        // 端到端：假 GitHub HTTP + 假 Agent CLI + 真实临时 git 仓库，跑通「拉取 → 规则 → 隔离 worktree → 执行 → Pending Review 回写」全链路（无网络、无真实 AI）
        .testTarget(
            name: "CollabDockE2ETests",
            dependencies: ["CollabDockCore"],
            path: "Tests/CollabDockE2ETests"
        )
    ]
)
