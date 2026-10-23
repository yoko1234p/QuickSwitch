// Optional contributor tool; uses only already installed Apple on-device language models.
import Foundation
import Translation

@main enum TranslateCatalog {
    static func main() async throws {
        let input = CommandLine.arguments[1]
        let output = CommandLine.arguments[2]
        let records = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: input))) as! [[String: Any]]
        let keys = Array(Set(records.filter { ($0["skip"] as? String ?? "").isEmpty }.compactMap { $0["key"] as? String })).sorted()
        var translations = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: output)))) as? [String: String] ?? [:]
        let source = Locale.Language(identifier: "zh-Hant")
        let target = Locale.Language(identifier: "en")
        guard await LanguageAvailability().status(from: source, to: target) == .installed else {
            throw NSError(domain: "Localization", code: 1, userInfo: [NSLocalizedDescriptionKey: "Install the Chinese and English Apple translation languages first."])
        }
        let session = TranslationSession(installedSource: source, target: target)
        let remaining = keys.filter { translations[$0] == nil }
        for start in stride(from: 0, to: remaining.count, by: 40) {
            let batch = Array(remaining[start..<min(start + 40, remaining.count)])
            let requests = batch.enumerated().map { index, key in
                TranslationSession.Request(sourceText: key, clientIdentifier: String(index))
            }
            let responses = try await session.translations(from: requests)
            for response in responses {
                if let id = response.clientIdentifier, let index = Int(id), batch.indices.contains(index) {
                    translations[batch[index]] = response.targetText
                }
            }
            let data = try JSONSerialization.data(withJSONObject: translations, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
            print("Translated \(min(start + batch.count, remaining.count))/\(remaining.count) (\(translations.count) total)")
            fflush(stdout)
        }
    }
}
