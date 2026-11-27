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
        .library(
            name: "CollabDockApp",
            targets: ["CollabDockApp"]
        ),
        .executable(
            name: "CollabDock",
            targets: ["CollabDock"]
        )
    ],
    targets: [
        .target(
            name: "CollabDockCore",
            path: "Sources/CollabDockCore"
        ),
        .target(
            name: "CollabDockApp",
            dependencies: ["CollabDockCore"],
            path: "Sources/CollabDockApp"
        ),
        .executableTarget(
            name: "CollabDock",
            dependencies: ["CollabDockApp"],
            path: "Sources/CollabDock"
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
        ),
        // App 层：用注入的假依赖测试 AppCoordinator 的状态流转（不启动 UI、不访问网络与本机 CLI）
        .testTarget(
            name: "CollabDockAppTests",
            dependencies: ["CollabDockApp", "CollabDockCore"],
            path: "Tests/CollabDockAppTests"
        )
    ]
)
