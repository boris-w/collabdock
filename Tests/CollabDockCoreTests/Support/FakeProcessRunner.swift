import Foundation
@testable import CollabDockCore

/// 假的 ProcessRunner：按「可执行文件名 + 参数」匹配预设输出，并记录所有调用。未匹配的调用返回退出码 127。
final class FakeProcessRunner: ProcessRunner, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var responses: [(name: String, args: [String], output: ProcessOutput)] = []

    /// 注册一个响应；`name` 是可执行文件的文件名（如 `gh`），`args` 需完全匹配
    func on(_ name: String, _ args: [String], stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        lock.withLock { responses.append((name, args, ProcessOutput(exitCode: exitCode, stdout: stdout, stderr: stderr))) }
    }

    var calls: [Call] { lock.withLock { recorded } }

    func calls(to name: String) -> [[String]] {
        calls.filter { ($0.executable as NSString).lastPathComponent == name }.map(\.arguments)
    }

    func run(executablePath: String, arguments: [String], environment: [String: String], timeoutSeconds: TimeInterval) async -> ProcessOutput {
        let name = (executablePath as NSString).lastPathComponent
        return lock.withLock {
            recorded.append(Call(executable: executablePath, arguments: arguments))
            return responses.first(where: { $0.name == name && $0.args == arguments })?.output
                ?? ProcessOutput(exitCode: 127, stdout: "", stderr: "fake: no response for \(name) \(arguments)")
        }
    }
}

/// 在临时目录里放一组「存在且可执行」的假二进制文件（FakeProcessRunner 不会真正执行它们）
struct FakeBinaries {
    let dir: URL

    init(_ names: [String]) throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("collabdock-fakebin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            let url = dir.appendingPathComponent(name)
            try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}
