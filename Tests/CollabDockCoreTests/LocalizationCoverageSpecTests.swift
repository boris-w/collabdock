import Foundation
import Testing
@testable import CollabDockCore

/// SPEC（实现前为红）：英文是一等界面语言（issue #4）。
///
/// 这组测试只看源码与 String Catalog，不约束 key 的风格（语义 key 或自然语言 key 都可以）：
/// 1. App 与 Core 各自有 `.xcstrings`，每个 key 都有非空的 `en` 与 `zh-Hans` 文案，两种语言的格式占位符一致；
/// 2. `Sources/` 里任何含中文的字符串字面量都必须是某个 catalog 的 key（即会被翻译），否则就是漏翻；
/// 3. 系统语言都不受支持时回退英文：Package 的 `defaultLocalization` 与 App 的 `CFBundleDevelopmentRegion` 为 `en`。
///
/// 暂不扫描（另有归属）：`Sources/CollabDockApp/Debug/`（仅 DEBUG 的截图 / 验收工具）、
/// `AgentCommandBuilder.swift`（内置提示词，下一个 PR 改为只发用户模板），以及用户可编辑的数据默认值
/// （触发关键词、任务模板），它们在运行时读出来作为白名单。
@Suite("SPEC — every user-facing string is localized into English and Simplified Chinese (issue #4)")
struct LocalizationCoverageSpecTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let excludedPathFragments = [
        "/Sources/CollabDockApp/Debug/",
        "/Sources/CollabDockCore/Agents/AgentCommandBuilder.swift",
    ]

    // MARK: 1. catalogs

    @Test("App and Core each ship a String Catalog")
    func catalogsExist() {
        #expect(!Self.catalogs(under: "Sources/CollabDockApp").isEmpty, "no .xcstrings under Sources/CollabDockApp")
        #expect(!Self.catalogs(under: "Sources/CollabDockCore").isEmpty, "no .xcstrings under Sources/CollabDockCore")
    }

    @Test("Every catalog entry has a non-empty English and Simplified Chinese value")
    func everyEntryIsTranslated() throws {
        var problems: [String] = []
        for url in Self.catalogs(under: "Sources") {
            let catalog = try Catalog(url: url)
            for entry in catalog.entries where entry.shouldTranslate {
                for language in ["en", "zh-Hans"] where entry.values(for: language, sourceLanguage: catalog.sourceLanguage).isEmpty {
                    problems.append("\(url.lastPathComponent): \"\(entry.key)\" has no \(language) value")
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.count) untranslated entries:\n\(problems.prefix(40).joined(separator: "\n"))")
    }

    @Test("English and Chinese values use the same format placeholders (a mismatch crashes or garbles at runtime)")
    func placeholdersMatch() throws {
        var problems: [String] = []
        for url in Self.catalogs(under: "Sources") {
            let catalog = try Catalog(url: url)
            for entry in catalog.entries where entry.shouldTranslate {
                let en = entry.values(for: "en", sourceLanguage: catalog.sourceLanguage)
                let zh = entry.values(for: "zh-Hans", sourceLanguage: catalog.sourceLanguage)
                guard let enFirst = en.first, let zhFirst = zh.first else { continue }
                if Self.placeholders(in: enFirst) != Self.placeholders(in: zhFirst) {
                    problems.append("\"\(entry.key)\": en \(Self.placeholders(in: enFirst)) vs zh-Hans \(Self.placeholders(in: zhFirst))")
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.prefix(40).joined(separator: "\n"))")
    }

    // MARK: 2. no untranslated Chinese literals

    @Test("Every Chinese string literal in Sources/ is a catalog key (otherwise English users would see Chinese)")
    func noUntranslatedChineseLiterals() throws {
        var keys = Set<String>()
        for url in Self.catalogs(under: "Sources") {
            for entry in try Catalog(url: url).entries {
                keys.insert(Self.normalize(catalogKey: entry.key))
            }
        }
        let allowlist = Self.userDataDefaults()

        var violations: [String] = []
        for file in Self.swiftFiles(under: "Sources") {
            let path = file.path
            if Self.excludedPathFragments.contains(where: { path.contains($0) }) { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for literal in SwiftLiteralScanner.literals(in: source) where Self.containsCJK(literal.text) {
                if literal.isMultiline {
                    violations.append("\(Self.relative(file)):\(literal.line): multi-line Chinese text")
                    continue
                }
                let normalized = Self.normalize(literal: literal.text)
                if keys.contains(normalized) || allowlist.contains(literal.text) { continue }
                violations.append("\(Self.relative(file)):\(literal.line): \"\(literal.text.prefix(60))\"")
            }
        }
        #expect(violations.isEmpty, "\(violations.count) Chinese literals are not localized:\n\(violations.prefix(60).joined(separator: "\n"))")
    }

    @Test("Self-check: the literal scanner finds strings, skips comments, and handles interpolation and URLs")
    func scannerSelfCheck() {
        let source = #"""
        // 注释里的中文不算
        let a = "设置" // 行尾注释：也不算
        /* 块注释 "不算" */
        let b = "共 \(count) 条，\(flag ? "是" : "否")"
        let c = URL(string: "https://example.com/a//b")!
        let d = #"原始字符串"#
        let e = """
            多行中文
            """
        """#
        let found = SwiftLiteralScanner.literals(in: source)
        let texts = found.map(\.text)
        #expect(texts.contains("设置"))
        #expect(texts.contains("共 \\(count) 条，\\(flag ? \"是\" : \"否\")") || texts.contains { $0.hasPrefix("共 ") })
        #expect(texts.contains("是") && texts.contains("否"), "string literals nested in an interpolation are scanned too")
        #expect(texts.contains("https://example.com/a//b"))
        #expect(texts.contains("原始字符串"))
        #expect(found.contains { $0.isMultiline && $0.text.contains("多行中文") })
        #expect(!texts.contains { $0.contains("注释") || $0.contains("不算") })
        #expect(Self.normalize(literal: "共 \\(count) 条") == Self.normalize(catalogKey: "共 %lld 条"))
        #expect(Self.normalize(literal: "已复制 \\(name)") == Self.normalize(catalogKey: "已复制 %@"))
        #expect(Self.normalize(literal: "第一行\\n第二行") == Self.normalize(catalogKey: "第一行\n第二行"))
    }

    // MARK: 3. fallback language

    @Test("When no system language is supported, macOS falls back to English")
    func developmentRegionIsEnglish() throws {
        let package = try String(contentsOf: Self.repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(package.contains(#"defaultLocalization: "en""#), "Package.swift defaultLocalization must be \"en\"")

        let plistData = try Data(contentsOf: Self.repoRoot.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(plist["CFBundleDevelopmentRegion"] as? String == "en")
        let localizations = plist["CFBundleLocalizations"] as? [String] ?? []
        #expect(Set(localizations).isSuperset(of: ["en", "zh-Hans"]), "the app must declare both localizations, got \(localizations)")
    }

    // MARK: - helpers

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) || (0x3000...0x303F).contains($0.value) }
    }

    /// 用户可编辑的数据默认值（不是界面文案）：触发关键词与任务模板
    static func userDataDefaults() -> Set<String> {
        var values = Set(TriggerRules().mentionKeywords)
        for preset in TaskPreset.defaults + TaskPreset.legacyFactoryDefaults {
            values.insert(preset.name)
            values.insert(preset.promptInstructions)
        }
        return values
    }

    static func relative(_ url: URL) -> String {
        String(url.path.dropFirst(repoRoot.path.count + 1))
    }

    static func files(under relativeDir: String, ext: String) -> [URL] {
        let dir = repoRoot.appendingPathComponent(relativeDir)
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == ext }.sorted { $0.path < $1.path }
    }

    static func catalogs(under relativeDir: String) -> [URL] { files(under: relativeDir, ext: "xcstrings") }
    static func swiftFiles(under relativeDir: String) -> [URL] { files(under: relativeDir, ext: "swift") }

    static let specifierRegex = try! NSRegularExpression(
        pattern: #"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?[@dDiuUxXoOfFeEgGcCsSpaA]"#
    )

    /// 占位符的类型序列（忽略位置编号 `1$`，因为中英文语序可以不同，但种类与个数必须一致）
    static func placeholders(in text: String) -> [String] {
        let ns = text as NSString
        let cleaned = ns.replacingOccurrences(of: "%%", with: "")
        let range = NSRange(location: 0, length: (cleaned as NSString).length)
        return specifierRegex.matches(in: cleaned, range: range).map {
            let s = (cleaned as NSString).substring(with: $0.range)
            return s.replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression)
        }.sorted()
    }

    static func normalize(catalogKey key: String) -> String {
        let range = NSRange(location: 0, length: (key as NSString).length)
        return specifierRegex.stringByReplacingMatches(in: key, range: range, withTemplate: "{}")
    }

    /// 把源码字面量还原成运行时字符串：插值 `\(...)` 视为一个占位符，常见转义还原为字符
    static func normalize(literal: String) -> String {
        var out = ""
        let chars = Array(literal)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "(" {
                    var depth = 1
                    var j = i + 2
                    while j < chars.count, depth > 0 {
                        if chars[j] == "(" { depth += 1 }
                        if chars[j] == ")" { depth -= 1 }
                        j += 1
                    }
                    out += "{}"
                    i = j
                    continue
                }
                switch n {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "'": out.append("'")
                default: out.append(n)
                }
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }
}

// MARK: - String Catalog reader

private struct Catalog {
    struct Entry {
        let key: String
        let shouldTranslate: Bool
        let localizations: [String: Any]

        /// 某语言的全部文案（含复数 / 设备变体）。源语言未显式写值时用 key 本身——但只接受像自然语言的 key，
        /// 防止语义 key（如 `settings.title`）在界面上原样露出。
        func values(for language: String, sourceLanguage: String) -> [String] {
            if let loc = localizations[language] as? [String: Any] {
                let leaves = Self.leafValues(loc)
                if !leaves.isEmpty { return leaves }
            }
            if language == sourceLanguage, Self.looksLikeNaturalText(key) { return [key] }
            return []
        }

        static func leafValues(_ node: [String: Any]) -> [String] {
            var result: [String] = []
            if let unit = node["stringUnit"] as? [String: Any],
               let value = unit["value"] as? String, !value.isEmpty,
               (unit["state"] as? String).map({ $0 == "translated" }) ?? true {
                result.append(value)
            }
            if let variations = node["variations"] as? [String: Any] {
                for case let group as [String: Any] in variations.values {
                    for case let child as [String: Any] in group.values {
                        result += leafValues(child)
                    }
                }
            }
            return result
        }

        static func looksLikeNaturalText(_ key: String) -> Bool {
            let identifierLike = key.range(of: #"^[A-Za-z0-9_]+(\.[A-Za-z0-9_\-]+)+$"#, options: .regularExpression) != nil
            return !identifierLike
        }
    }

    let sourceLanguage: String
    let entries: [Entry]

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        sourceLanguage = root["sourceLanguage"] as? String ?? "en"
        let strings = root["strings"] as? [String: Any] ?? [:]
        entries = strings.keys.sorted().map { key in
            let body = strings[key] as? [String: Any] ?? [:]
            return Entry(
                key: key,
                shouldTranslate: (body["shouldTranslate"] as? Bool) ?? true,
                localizations: body["localizations"] as? [String: Any] ?? [:]
            )
        }
    }
}

// MARK: - Swift string literal scanner

/// 极简 Swift 词法扫描：识别普通 / 原始 / 多行字符串字面量（含插值里嵌套的字面量），跳过行注释与块注释。
enum SwiftLiteralScanner {
    struct Literal {
        let text: String
        let line: Int
        let isMultiline: Bool
    }

    static func literals(in source: String) -> [Literal] {
        var scanner = Scanner(chars: Array(source))
        scanner.scanCode(untilCloseParen: false)
        return scanner.found
    }

    private struct Scanner {
        let chars: [Character]
        var i = 0
        var line = 1
        var found: [Literal] = []

        init(chars: [Character]) { self.chars = chars }

        func peek(_ offset: Int = 0) -> Character? {
            let j = i + offset
            return j < chars.count ? chars[j] : nil
        }

        func starts(with s: String) -> Bool {
            let a = Array(s)
            guard i + a.count <= chars.count else { return false }
            return Array(chars[i..<(i + a.count)]) == a
        }

        mutating func advance(_ n: Int = 1) {
            for _ in 0..<n where i < chars.count {
                if chars[i] == "\n" { line += 1 }
                i += 1
            }
        }

        /// 扫描代码；`untilCloseParen` 为 true 时用于插值内部，遇到配对的 `)` 返回
        mutating func scanCode(untilCloseParen: Bool) {
            var depth = 0
            while i < chars.count {
                if starts(with: "//") {
                    while let c = peek(), c != "\n" { advance() }
                } else if starts(with: "/*") {
                    advance(2)
                    while i < chars.count, !starts(with: "*/") { advance() }
                    advance(2)
                } else if peek() == "#" {
                    var hashes = 0
                    while peek(hashes) == "#" { hashes += 1 }
                    if peek(hashes) == "\"" {
                        advance(hashes)
                        scanString(hashes: hashes)
                    } else {
                        advance()
                    }
                } else if peek() == "\"" {
                    scanString(hashes: 0)
                } else if untilCloseParen, peek() == "(" {
                    depth += 1
                    advance()
                } else if untilCloseParen, peek() == ")" {
                    if depth == 0 { advance(); return }
                    depth -= 1
                    advance()
                } else {
                    advance()
                }
            }
        }

        /// 当前位于开引号（`"` 或 `"""`）上；`hashes` 为原始字符串的 `#` 个数
        mutating func scanString(hashes: Int) {
            let startLine = line
            let multiline = starts(with: "\"\"\"")
            let quote = multiline ? "\"\"\"" : "\""
            advance(quote.count)
            let terminator = quote + String(repeating: "#", count: hashes)
            let escape = "\\" + String(repeating: "#", count: hashes)
            var text = ""
            while i < chars.count {
                if starts(with: terminator) {
                    advance(terminator.count)
                    break
                }
                if !multiline, peek() == "\n" { break }
                if starts(with: escape) {
                    let after = peek(escape.count)
                    if after == "(" {
                        // 插值：原样记录到文本，同时扫描其中嵌套的字面量
                        let begin = i
                        advance(escape.count + 1)
                        scanCode(untilCloseParen: true)
                        text += String(chars[begin..<i])
                        continue
                    }
                    text += String(chars[i..<min(chars.count, i + escape.count + 1)])
                    advance(escape.count + 1)
                    continue
                }
                text.append(chars[i])
                advance()
            }
            found.append(Literal(text: text, line: startLine, isMultiline: multiline))
        }
    }
}
