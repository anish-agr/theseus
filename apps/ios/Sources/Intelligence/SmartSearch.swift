// Forgiving inventory search. You should not need the exact word:
// "where are my keys" strips its filler, "sofa" finds the couch, and
// "mugg" survives the typo. Three layers, all on-device and instant:
//   1. stopword stripping — questions become keywords
//   2. prefix/containment token matching — plurals and typos-at-the-end
//   3. Apple NLEmbedding word vectors — synonyms and near-meanings,
//      built into iOS, no download (this is the CLIP stopgap; CLIP
//      later adds the same forgiveness to descriptions and images)
import Foundation
import NaturalLanguage

enum SmartSearch {
    private static let embedding = NLEmbedding.wordEmbedding(for: .english)

    private static let stopwords: Set<String> = [
        "where", "is", "are", "my", "the", "a", "an", "find", "whats",
        "what", "did", "i", "put", "go", "to", "me", "show", "in",
        "on", "of", "for", "take", "locate", "look",
    ]

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
    }

    /// Score a thing against a query; nil means "not a match". Every
    /// meaningful query token must land somewhere in the thing.
    static func score(query: String, thing: Thing) -> Double? {
        let qTokens = tokens(query)
        guard !qTokens.isEmpty else { return 0 }
        let hayTokens = tokens(thing.searchHaystack)
        guard !hayTokens.isEmpty else { return nil }
        let nameTokens = Set(tokens(thing.displayName))

        var total = 0.0
        for q in qTokens {
            var best = 0.0
            for h in hayTokens {
                let s = tokenScore(query: q, candidate: h)
                if s > best { best = s }
                if nameTokens.contains(h), s > 0 {
                    best = max(best, min(1.0, s + 0.15))  // name > OCR
                }
            }
            if best < 0.35 {
                return nil        // one dud token sinks the match
            }
            total += best
        }
        return total / Double(qTokens.count)
    }

    private static func tokenScore(query: String,
                                   candidate: String) -> Double {
        if candidate == query { return 1.0 }
        if candidate.hasPrefix(query) || query.hasPrefix(candidate) {
            let overlap = Double(min(query.count, candidate.count))
                / Double(max(query.count, candidate.count))
            return 0.7 + 0.25 * overlap       // "mug" ~ "mugs" ~ "mugg"
        }
        if query.count >= 4, candidate.contains(query) {
            return 0.6
        }
        // word vectors: "sofa" ~ "couch", "jacket" ~ "coat"
        if let embedding,
           embedding.contains(query), embedding.contains(candidate) {
            let d = embedding.distance(between: query, and: candidate)
            let similarity = 1.0 - d / 2.0     // cosine distance -> 0..1
            if similarity > 0.62 {
                return 0.45 + 0.5 * similarity
            }
        }
        return 0
    }
}
