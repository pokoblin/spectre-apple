import Foundation
import Testing

/// The String Catalogs of the app and of SpectreKit: every string the user
/// sees, in every language the app has (docs/localization.md). Run
/// scripts/sync-strings.sh after changing what the code shows; this then
/// fails until each new string is translated.
@Suite("Localization")
struct LocalizationTests {
    /// Besides English, the source language.
    static let languages = ["zh-Hans"]

    static let catalogs = [
        "App/Shared/Localizable.xcstrings",
        "App/Shared/InfoPlist.xcstrings",
        "Packages/SpectreKit/Sources/SpectreKit/Localizable.xcstrings",
    ]

    // MARK: The catalog format (the parts checked here)

    struct Catalog: Decodable {
        var sourceLanguage: String
        var strings: [String: Entry]
    }

    struct Entry: Decodable {
        var shouldTranslate: Bool?
        var extractionState: String?
        var localizations: [String: Localization]?
    }

    struct Localization: Decodable {
        var stringUnit: Unit?
        var variations: [String: [String: Localization]]? // "plural": ["one": …, "other": …]

        /// Every string this localization holds, with where (for messages).
        func units(_ path: String = "") -> [(path: String, unit: Unit)] {
            var all = stringUnit.map { [(path, $0)] } ?? []
            for (kind, cases) in variations ?? [:] {
                for (name, localization) in cases { all += localization.units("\(path)/\(kind).\(name)") }
            }
            return all
        }
    }

    struct Unit: Decodable {
        var state: String
        var value: String
    }

    static func load(_ path: String) throws -> Catalog {
        // Packages/SpectreKit/Tests/SpectreKitTests/LocalizationTests.swift → the repository.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: root.appending(path: path)))
    }

    /// The format specifiers in a string, without their positions (%1$@ is %@),
    /// sorted: a translation may reorder them, but not drop or change one.
    static func placeholders(_ text: String) -> [String] {
        text.matches(of: /%(?:\d+\$)?(lld|ld|d|@|\.?\d*f)/).map { "%" + $0.output.1 }.sorted()
    }

    // MARK: Checks

    @Test(arguments: catalogs)
    func englishIsTheSource(_ path: String) throws {
        #expect(try Self.load(path).sourceLanguage == "en")
    }

    /// Strings the code no longer shows: delete them (scripts/sync-strings.sh marks them).
    @Test(arguments: catalogs)
    func noStaleStrings(_ path: String) throws {
        let stale = try Self.load(path).strings.filter { $0.value.extractionState == "stale" }.keys.sorted()
        #expect(stale.isEmpty, "\(path): no longer in the code: \(stale)")
    }

    @Test(arguments: catalogs)
    func everyLanguageHasEveryString(_ path: String) throws {
        let catalog = try Self.load(path)
        for (key, entry) in catalog.strings.sorted(by: { $0.key < $1.key }) where entry.shouldTranslate != false {
            for language in Self.languages {
                guard let localization = entry.localizations?[language] else {
                    Issue.record("\(path): \(language) has no \"\(key)\"")
                    continue
                }
                for (place, unit) in localization.units() where unit.state != "translated" || unit.value.isEmpty {
                    Issue.record("\(path): \(language)\(place) of \"\(key)\" is \(unit.state)")
                }
            }
        }
    }

    @Test(arguments: catalogs)
    func translationsKeepThePlaceholders(_ path: String) throws {
        let catalog = try Self.load(path)
        for (key, entry) in catalog.strings where entry.shouldTranslate != false {
            // The source: the key itself, unless English gives the text (Info.plist keys).
            let source = Self.placeholders(entry.localizations?["en"]?.stringUnit?.value ?? key)
            for (language, localization) in entry.localizations ?? [:] {
                for (place, unit) in localization.units() where Self.placeholders(unit.value) != source {
                    Issue.record("\(path): \(language)\(place) of \"\(key)\" has \(Self.placeholders(unit.value)), not \(source)")
                }
            }
        }
    }

    @Test func placeholdersIgnoreTheirPositions() {
        #expect(Self.placeholders("Reconnecting… (attempt %lld of %lld)") == ["%lld", "%lld"])
        #expect(Self.placeholders("%2$@ — %1$lld") == Self.placeholders("%lld %@"))
        #expect(Self.placeholders("100%% sure") == [])
    }
}
