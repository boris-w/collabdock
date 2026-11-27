import Foundation

/// Resolved effective language used for UI rendering and GitHub review output (issue #4).
public enum ResolvedLanguage: String, Codable, Hashable, Sendable {
    case zhHans = "zh-Hans"
    case en = "en"

    public var lprojCode: String { rawValue }
}

/// User-configurable interface language preference.
public enum AppLanguage: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    /// Resolves to the first supported language in `preferredLanguages`, falling back to English.
    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> ResolvedLanguage {
        switch self {
        case .zhHans:
            return .zhHans
        case .en:
            return .en
        case .system:
            for raw in preferredLanguages {
                let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if normalized.hasPrefix("zh") {
                    return .zhHans
                }
                if normalized.hasPrefix("en") {
                    return .en
                }
            }
            return .en
        }
    }

    /// Value to write to `UserDefaults.standard` `"AppleLanguages"` (`nil` removes override to follow system).
    public var appleLanguagesOverride: [String]? {
        switch self {
        case .system: return nil
        case .en: return ["en"]
        case .zhHans: return ["zh-Hans"]
        }
    }

    public var displayName: String {
        switch self {
        case .system:
            return CoreL10n.string("System")
        case .zhHans:
            return CoreL10n.string("Simplified Chinese")
        case .en:
            return "English"
        }
    }
}

/// Language used for text CollabDock writes to GitHub (pending reviews, inline comments, local reports, council synthesis).
public enum ReviewLanguage: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case followUI = "followUI"
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    public func resolved(uiLanguage: ResolvedLanguage) -> ResolvedLanguage {
        switch self {
        case .followUI: return uiLanguage
        case .zhHans: return .zhHans
        case .en: return .en
        }
    }

    public var displayName: String {
        switch self {
        case .followUI:
            return CoreL10n.string("Follow UI")
        case .zhHans:
            return CoreL10n.string("Simplified Chinese")
        case .en:
            return "English"
        }
    }
}

/// Safe localization helper for `CollabDockCore`.
///
/// Avoids SwiftPM's generated `Bundle.module` (which crashes when `.bundle` lives under
/// `CollabDock.app/Contents/Resources/` rather than the `.app` root) and supports explicit
/// per-call language selection for review output and offscreen snapshot rendering.
public enum CoreL10n {
    private final class BundleToken {}
    private static let bundleName = "CollabDock_CollabDockCore"

    private static let overrideLock = NSLock()
    private nonisolated(unsafe) static var _overrideLanguage: ResolvedLanguage?

    public static var overrideLanguage: ResolvedLanguage? {
        get { overrideLock.withLock { _overrideLanguage } }
        set { overrideLock.withLock { _overrideLanguage = newValue } }
    }

    public static var currentLanguage: ResolvedLanguage {
        if let override = overrideLanguage {
            return override
        }
        return AppLanguage.system.resolved()
    }

    public static let resourceBundle: Bundle = {
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle(for: BundleToken.self).resourceURL,
            Bundle(for: BundleToken.self).bundleURL,
            Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent(),
            Bundle.main.executableURL?.deletingLastPathComponent()
        ]
        for candidate in candidates.compactMap({ $0 }) {
            let bundleURL = candidate.appendingPathComponent("\(bundleName).bundle")
            if let bundle = Bundle(url: bundleURL) {
                return bundle
            }
        }
        return Bundle.main
    }()

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var lprojBundles: [ResolvedLanguage: Bundle] = [:]
    private nonisolated(unsafe) static var catalogByLanguage: [String: [String: String]]? = nil
    private nonisolated(unsafe) static var didLoadCatalog = false

    private static func lprojBundle(for language: ResolvedLanguage) -> Bundle? {
        cacheLock.lock()
        if let cached = lprojBundles[language] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let foundPath = resourceBundle.path(forResource: language.lprojCode, ofType: "lproj")
            ?? resourceBundle.path(forResource: language.lprojCode.lowercased(), ofType: "lproj")
        guard let path = foundPath, let bundle = Bundle(path: path) else {
            return nil
        }

        cacheLock.lock()
        lprojBundles[language] = bundle
        cacheLock.unlock()
        return bundle
    }

    /// Loads translations from either a compiled `Localizable.loctable` (Xcode builds) or
    /// the raw `Localizable.xcstrings` JSON shipped by SwiftPM CLI builds.
    private static func catalogValue(forKey key: String, language: ResolvedLanguage) -> String? {
        cacheLock.lock()
        if !didLoadCatalog {
            didLoadCatalog = true
            var parsed: [String: [String: String]] = [:]
            if let url = resourceBundle.url(forResource: "Localizable", withExtension: "loctable"),
               let data = try? Data(contentsOf: url),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                for (lang, rawMap) in plist {
                    if let map = rawMap as? [String: String] {
                        parsed[lang] = map
                    }
                }
            }
            if parsed.isEmpty,
               let url = resourceBundle.url(forResource: "Localizable", withExtension: "xcstrings"),
               let data = try? Data(contentsOf: url),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let strings = root["strings"] as? [String: Any] {
                for (entryKey, rawBody) in strings {
                    guard let body = rawBody as? [String: Any],
                          let localizations = body["localizations"] as? [String: Any] else {
                        continue
                    }
                    for (lang, rawLoc) in localizations {
                        if let loc = rawLoc as? [String: Any],
                           let unit = loc["stringUnit"] as? [String: Any],
                           let value = unit["value"] as? String,
                           !value.isEmpty {
                            parsed[lang, default: [:]][entryKey] = value
                        }
                    }
                }
            }
            catalogByLanguage = parsed
        }
        let map = catalogByLanguage?[language.lprojCode] ?? catalogByLanguage?[language.lprojCode.lowercased()]
        cacheLock.unlock()
        return map?[key]
    }

    public static func string(_ key: String, language: ResolvedLanguage? = nil) -> String {
        let lang = language ?? currentLanguage
        if let bundle = lprojBundle(for: lang) {
            let value = bundle.localizedString(forKey: key, value: "\u{0000}", table: "Localizable")
            if value != "\u{0000}" {
                return value
            }
        }
        if let value = catalogValue(forKey: key, language: lang) {
            return value
        }
        return resourceBundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    public static func format(_ key: String, language: ResolvedLanguage? = nil, _ args: CVarArg...) -> String {
        let lang = language ?? currentLanguage
        let template = string(key, language: lang)
        guard !args.isEmpty else { return template }
        return String(format: template, locale: Locale(identifier: lang.lprojCode), arguments: args)
    }
}
