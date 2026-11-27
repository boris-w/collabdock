import Foundation
import Testing
@testable import CollabDockCore

/// 界面语言设置（issue #4）。
///
/// - 界面语言 `AppLanguage`：跟随系统 / 简体中文 / English。系统语言里没有支持的语言时回退到英文。
/// - 切换界面语言通过 App 级 `AppleLanguages` 覆盖实现（重启后生效）；「跟随系统」表示移除覆盖。
/// - 审查语言随 CollabDock 自写 GitHub 文案一起移除（Lody-only），旧配置里的 `reviewLanguage` 被忽略（见 LodyOnlySpecTests）。
@Suite("UI language settings (issue #4)")
struct LanguageSettingsSpecTests {

    // MARK: settings model

    @Test("Default: the UI language follows the system")
    func defaults() {
        let settings = AppSettings()
        #expect(settings.appLanguage == .system)
    }

    @Test("Settings saved before this feature decode with the defaults")
    func legacySettingsDecode() throws {
        let legacy = #"{"pollIntervalSeconds": 120, "defaultEngine": "lody"}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        #expect(decoded.appLanguage == .system)
        #expect(decoded.pollIntervalSeconds == 120)
    }

    @Test("The UI language survives a save / load round trip")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.appLanguage = .en
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.appLanguage == .en)

        settings.appLanguage = .zhHans
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(again.appLanguage == .zhHans)
    }

    @Test("An unknown language value (e.g. written by a newer version) falls back to the default instead of failing the whole file")
    func unknownValuesFallBack() throws {
        let json = #"{"pollIntervalSeconds": 300, "appLanguage": "fr"}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.appLanguage == .system)
        #expect(decoded.pollIntervalSeconds == 300)
    }

    @Test("The UI language picker offers exactly: System, 简体中文, English")
    func pickerChoices() {
        #expect(AppLanguage.allCases == [.system, .zhHans, .en])
    }

    // MARK: resolving the effective language

    @Test("Following the system picks the first supported language in the system's preference order")
    func systemResolution() {
        #expect(AppLanguage.system.resolved(preferredLanguages: ["en-US"]) == .en)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["en-GB", "zh-Hans-CN"]) == .en)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN", "en-US"]) == .zhHans)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh-Hant-TW"]) == .zhHans)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh-HK"]) == .zhHans)
        // 不支持的语言跳过，继续看下一个偏好
        #expect(AppLanguage.system.resolved(preferredLanguages: ["ja-JP", "zh-Hans-CN"]) == .zhHans)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "en-US", "zh-Hans"]) == .en)
    }

    @Test("A system with no supported language falls back to English")
    func unsupportedSystemFallsBackToEnglish() {
        #expect(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "de-DE"]) == .en)
        #expect(AppLanguage.system.resolved(preferredLanguages: []) == .en)
    }

    @Test("An explicit UI language ignores the system preference")
    func explicitUILanguage() {
        #expect(AppLanguage.en.resolved(preferredLanguages: ["zh-Hans-CN"]) == .en)
        #expect(AppLanguage.zhHans.resolved(preferredLanguages: ["en-US"]) == .zhHans)
    }

    // MARK: applying the UI language

    @Test("Applying a UI language: an explicit choice overrides AppleLanguages, following the system removes the override")
    func appleLanguagesOverride() {
        #expect(AppLanguage.system.appleLanguagesOverride == nil)
        #expect(AppLanguage.en.appleLanguagesOverride == ["en"])
        #expect(AppLanguage.zhHans.appleLanguagesOverride == ["zh-Hans"])
    }
}
