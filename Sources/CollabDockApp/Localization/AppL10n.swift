import Foundation
import CollabDockCore

/// Safe localization helper for `CollabDockApp`.
///
/// Shares `CoreL10n.currentLanguage` (including `CoreL10n.overrideLanguage`) so offscreen
/// snapshots and runtime previews switch Core and App strings in lockstep, and safely finds
/// `CollabDock_CollabDockApp.bundle` under `Contents/Resources/` inside packaged `.app` bundles.
public enum AppL10n {
    private final class BundleToken {}
    private static let bundleName = "CollabDock_CollabDockApp"

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
        let lang = language ?? CoreL10n.currentLanguage
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
        let lang = language ?? CoreL10n.currentLanguage
        let template = string(key, language: lang)
        guard !args.isEmpty else { return template }
        return String(format: template, locale: Locale(identifier: lang.lprojCode), arguments: args)
    }
}

func L(_ key: String) -> String {
    AppL10n.string(key)
}

func L(_ key: String, _ args: CVarArg...) -> String {
    let lang = CoreL10n.currentLanguage
    let template = AppL10n.string(key, language: lang)
    guard !args.isEmpty else { return template }
    return String(format: template, locale: Locale(identifier: lang.lprojCode), arguments: args)
}
