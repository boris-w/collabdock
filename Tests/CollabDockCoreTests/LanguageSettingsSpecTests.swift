import Foundation
import Testing
@testable import CollabDockCore

/// SPEC（实现前为红）：界面语言与审查语言（issue #4）。
///
/// - 界面语言 `AppLanguage`：跟随系统 / 简体中文 / English。系统语言里没有支持的语言时回退到英文。
/// - 审查语言 `ReviewLanguage`：写回 GitHub 的审查正文、本地报告、会诊合并文字使用的语言；默认跟随界面语言，
///   可单独指定（界面用英文、PR 上用中文写，或者反过来）。
/// - 切换界面语言通过 App 级 `AppleLanguages` 覆盖实现（重启后生效）；「跟随系统」表示移除覆盖。
@Suite("SPEC — UI language and review language settings (issue #4)")
struct LanguageSettingsSpecTests {

    // MARK: settings model

    @Test("Defaults: UI language follows the system, review language follows the UI")
    func defaults() {
        let settings = AppSettings()
        #expect(settings.appLanguage == .system)
        #expect(settings.reviewLanguage == .followUI)
    }

    @Test("Settings saved before this feature decode with the defaults")
    func legacySettingsDecode() throws {
        let legacy = #"{"pollIntervalSeconds": 120, "defaultEngine": "lody"}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        #expect(decoded.appLanguage == .system)
        #expect(decoded.reviewLanguage == .followUI)
        #expect(decoded.pollIntervalSeconds == 120)
    }

    @Test("Both language choices survive a save / load round trip")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.appLanguage = .en
        settings.reviewLanguage = .zhHans
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.appLanguage == .en)
        #expect(decoded.reviewLanguage == .zhHans)

        settings.appLanguage = .zhHans
        settings.reviewLanguage = .en
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(again.appLanguage == .zhHans)
        #expect(again.reviewLanguage == .en)
    }

    @Test("An unknown language value (e.g. written by a newer version) falls back to the default instead of failing the whole file")
    func unknownValuesFallBack() throws {
        let json = #"{"pollIntervalSeconds": 300, "appLanguage": "fr", "reviewLanguage": "ja"}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.appLanguage == .system)
        #expect(decoded.reviewLanguage == .followUI)
        #expect(decoded.pollIntervalSeconds == 300)
    }

    @Test("The settings picker offers exactly: System, 简体中文, English")
    func pickerChoices() {
        #expect(AppLanguage.allCases == [.system, .zhHans, .en])
        #expect(ReviewLanguage.allCases == [.followUI, .zhHans, .en])
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

    @Test("Review language follows the effective UI language unless set explicitly")
    func reviewLanguageResolution() {
        #expect(ReviewLanguage.followUI.resolved(uiLanguage: .en) == .en)
        #expect(ReviewLanguage.followUI.resolved(uiLanguage: .zhHans) == .zhHans)
        #expect(ReviewLanguage.zhHans.resolved(uiLanguage: .en) == .zhHans)
        #expect(ReviewLanguage.en.resolved(uiLanguage: .zhHans) == .en)
    }

    // MARK: applying the UI language

    @Test("Applying a UI language: an explicit choice overrides AppleLanguages, following the system removes the override")
    func appleLanguagesOverride() {
        #expect(AppLanguage.system.appleLanguagesOverride == nil)
        #expect(AppLanguage.en.appleLanguagesOverride == ["en"])
        #expect(AppLanguage.zhHans.appleLanguagesOverride == ["zh-Hans"])
    }
}
