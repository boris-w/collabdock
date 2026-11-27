import Foundation
@testable import CollabDockCore

/// 假的 AI CLI（如 `claude`）：一个 /bin/sh 脚本，记录收到的参数、环境变量、工作目录和 PID，
/// 然后按预设回放 stream-json 输出与退出码。用来验证宿主真实传给 CLI 的东西（只读沙箱参数、Token 剥离、Prompt 隔离），
/// 而不依赖任何真实模型。
struct FakeAgentCLI {
    let executable: URL
    let recordDir: URL

    /// - Parameters:
    ///   - name: 可执行文件名（决定 PATH 查找名，如 `claude`）
    ///   - stdoutLines: 回放到 stdout 的行（stream-json）
    ///   - exitCode: 退出码
    ///   - stderr: 回放到 stderr 的内容
    ///   - hangSeconds: >0 时先启动一个子进程 sleep 并等待它，用来模拟长时间运行（以及会派生子进程的真实 CLI）
    ///   - outputFileFlag / outputFileContent: 设置后，把内容写到该参数后面给出的文件路径（如 codex 的 `-o <file>`）
    init(
        in directory: URL,
        name: String = "claude",
        stdoutLines: [String],
        exitCode: Int32 = 0,
        stderr: String = "",
        hangSeconds: Int = 0,
        outputFileFlag: String? = nil,
        outputFileContent: String = ""
    ) throws {
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        recordDir = directory.appendingPathComponent("record-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
        executable = bin.appendingPathComponent(name)

        try (stdoutLines.joined(separator: "\n") + "\n")
            .write(to: recordDir.appendingPathComponent("stdout.jsonl"), atomically: true, encoding: .utf8)
        try stderr.write(to: recordDir.appendingPathComponent("stderr.txt"), atomically: true, encoding: .utf8)
        try outputFileContent.write(to: recordDir.appendingPathComponent("outfile.txt"), atomically: true, encoding: .utf8)

        let rec = recordDir.path
        let hang = hangSeconds > 0
            ? "sleep \(hangSeconds) &\necho $! > '\(rec)/child_pid'\nwait\n"
            : ""
        let writeOutputFile = outputFileFlag.map { flag in
            "prev=\"\"; out=\"\"\nfor a in \"$@\"; do if [ \"$prev\" = '\(flag)' ]; then out=\"$a\"; fi; prev=\"$a\"; done\n"
                + "if [ -n \"$out\" ]; then cat '\(rec)/outfile.txt' > \"$out\"; fi\n"
        } ?? ""
        let script = """
        #!/bin/sh
        printf '%s\\0' "$@" > '\(rec)/argv'
        env > '\(rec)/env'
        pwd -P > '\(rec)/cwd'
        echo $$ > '\(rec)/pid'
        touch '\(rec)/started'
        \(writeOutputFile)\(hang)cat '\(rec)/stderr.txt' >&2
        cat '\(rec)/stdout.jsonl'
        exit \(exitCode)

        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    var argv: [String] {
        guard let data = try? Data(contentsOf: recordDir.appendingPathComponent("argv")) else { return [] }
        return data.split(separator: 0, omittingEmptySubsequences: false)
            .dropLast()
            .map { String(decoding: $0, as: UTF8.self) }
    }

    var environmentKeys: Set<String> {
        guard let text = try? String(contentsOf: recordDir.appendingPathComponent("env"), encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { line in
            line.split(separator: "=", maxSplits: 1).first.map(String.init)
        })
    }

    var workingDirectory: String? {
        (try? String(contentsOf: recordDir.appendingPathComponent("cwd"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasStarted: Bool {
        FileManager.default.fileExists(atPath: recordDir.appendingPathComponent("started").path)
    }

    func recordedPID(_ file: String = "pid") -> pid_t? {
        (try? String(contentsOf: recordDir.appendingPathComponent(file), encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// 取某个参数后面紧跟的值（如 `--permission-mode` → `plan`）
    func value(after flag: String) -> String? {
        let args = argv
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    /// 为假 CLI 构造一个环境快照：只登记这一个引擎
    func environmentSnapshot(engine: AgentEngine) -> EnvironmentSnapshot {
        EnvironmentSnapshot(
            resolvedPATH: "\(executable.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin",
            git: CLIProbeStatus(name: "git", isInstalled: true, executablePath: "/usr/bin/git"),
            gh: CLIProbeStatus(name: "gh", isInstalled: false),
            engines: [engine: CLIProbeStatus(name: executable.lastPathComponent, isInstalled: true, executablePath: executable.path)],
            githubAuth: GitHubAuthSnapshot(isAuthenticated: true, username: "reviewer"),
            discoveredModels: [:]
        )
    }
}

func isProcessAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

/// Claude Code `--output-format stream-json` 风格的回放事件
enum ClaudeStream {
    static func initEvent(sessionID: String) -> String {
        #"{"type":"system","subtype":"init","session_id":"\#(sessionID)"}"#
    }

    static func toolUse(_ tool: String, path: String) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"\#(tool)","input":{"file_path":"\#(path)"}}]}}"#
    }

    static func result(sessionID: String, structuredOutput: String) -> String {
        #"{"type":"result","subtype":"success","session_id":"\#(sessionID)","result":"","structured_output":\#(structuredOutput),"usage":{"input_tokens":1200,"output_tokens":300}}"#
    }
}
