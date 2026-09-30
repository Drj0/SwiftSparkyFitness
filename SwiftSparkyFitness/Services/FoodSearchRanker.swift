//
//  FoodSearchRanker.swift
//  SwiftSparkyFitness
//
//  One deterministic order for every food search source: the user's own
//  foods, INDB, USDA and Open Food Facts are scored on the same scale, then
//  de-duplicated and capped per source.
//
//  A score is the sum of independent parts, each a named weight below, so
//  tuning is editing a number rather than rethinking an order:
//
//  - name match      how well the query matches the name (the big one):
//                    exact > plain ("Boiled rice") > head noun ("Moong dal")
//                    > all words > word prefixes > spelling variant
//  - personal        the user's own foods — they've logged them before
//  - Indian          INDB dishes, and OFF products (searched India-only)
//  - source quality  curated datasets over user-submitted barcodes
//  - completeness    all three macros present
//  - extra words     "Rice" beats "Rice flakes cutlet with mint chutney"
//  - provider rank   each provider's own relevance order, as a light nudge
//
//  Ties break on source, provider position, then id, so the same inputs
//  always give the same list no matter which source answered first.
//
//  Cost: tokenising ~100 short names, microseconds. It runs on every partial
//  update, which is fine at this size; anything smarter (fuzzy distance,
//  embeddings) would need measuring first.
//

import Foundation

/// Lowercased, diacritic-free word splitting plus a transliteration-tolerant
/// "squash" for romanised Indian food names.
nonisolated enum FoodSearchText {
    static func words(_ text: String) -> [String] {
        tokens(fold(text)[...])
    }

    /// Lowercased and diacritic-free. Most food names are plain ASCII, where
    /// `lowercased()` is all it takes and full Unicode folding is the single
    /// most expensive step in ranking.
    static func fold(_ text: String) -> String {
        text.utf8.allSatisfy { $0 < 128 }
            ? text.lowercased()
            : text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Splits on UTF-8 bytes, not Characters: grapheme-aware iteration was
    /// 90% of ranking time. ASCII letters and digits make words; every
    /// non-ASCII byte counts as a letter, so "Dahi" and "दही" both hold.
    static func tokens(_ folded: Substring) -> [String] {
        folded.utf8
            .split { !(($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 >= 128) }
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Spelling-insensitive key: "channa" and "chana", "dhal" and "dal",
    /// "rajmah" and "rajma" all meet. Doubled letters collapse and an `h`
    /// after a consonant drops — the two commonest variations in how Indian
    /// dish names get romanised.
    static func squash(_ word: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(word.utf8.count)
        for byte in word.utf8 {
            if byte == out.last { continue }
            // "h" after an ASCII consonant: 104 = h; 97/101/105/111/117 = a e i o u.
            if byte == 104, let last = out.last, last < 128, last != 97, last != 101, last != 105, last != 111, last != 117 { continue }
            out.append(byte)
        }
        return String(decoding: out, as: UTF8.self)
    }

    struct Alternative {
        let words: [String]
        /// What the dish *is*: the last word before any comma or "with".
        /// "Moong dal" → dal, "Rice flakes" → flakes, "Rice, white, cooked"
        /// → rice, "Biryani with chicken" → biryani.
        let head: String
        /// Words before any comma or "with" — the only ones that count as
        /// "extra": USDA's trailing qualifiers ("brown, long-grain, cooked")
        /// describe the same food rather than a different one.
        let headLength: Int
    }

    /// The alternative names packed into one: INDB writes "Chapati/Roti" and
    /// "Kidney bean curry (Rajmah curry)"; USDA writes "Rice, white, cooked".
    /// Commas stay inside an alternative — they're qualifiers, not synonyms.
    static func alternatives(folded name: String) -> [Alternative] {
        name.utf8.split { $0 == 47 || $0 == 40 || $0 == 41 }  // / ( )
            .compactMap { part in
                let words = tokens(Substring(part))
                let beforeComma = tokens(Substring(part.split(separator: 44, maxSplits: 1, omittingEmptySubsequences: false)[0]))  // ,
                let headWords = beforeComma.prefix { $0 != "with" }
                guard let head = headWords.last ?? words.last else { return nil }
                return Alternative(words: words, head: head, headLength: max(headWords.count, 1))
            }
    }
}

nonisolated enum FoodSearchRanker {
    struct Weights {
        // Name match — the best tier that applies wins.
        var exactName: Double = 100
        /// Exact once plain qualifiers are ignored: "Boiled rice",
        /// "Rice, white, cooked", "Plain dosa" for "rice"/"dosa".
        var plainName: Double = 90
        /// Every query word present, the last one being the dish's head noun:
        /// "dal" → "Moong dal" over "Dal parantha".
        var headNoun: Double = 60
        var allWordsExact: Double = 45
        var allWordsPrefix: Double = 30
        var spellingVariant: Double = 25
        /// A provider matched on something other than the name (a brand,
        /// an ingredient). Kept, but at the bottom.
        var noNameMatch: Double = 0

        /// Enough that the user's own food leads whenever its name holds
        /// every query word — but an exact canonical dish ("Chapati/Roti"
        /// for "roti") still beats their loosely matching "Roti wrap".
        var personal: Double = 70
        var indianDish: Double = 12
        var indiaProduct: Double = 4
        var curatedSource: Double = 8
        var completeMacros: Double = 4

        var extraWordPenalty: Double = 2
        var maxExtraWordPenalty: Double = 16
        var providerRankPenalty: Double = 0.25

        /// Qualifiers that don't change what the food *is*.
        var plainWords: Set<String> = ["plain", "boiled", "cooked", "steamed", "raw", "fresh", "white", "whole", "homemade", "nfs"]

        static let standard = Weights()
    }

    /// Ranks results from several sources into one list. `lists` are each
    /// source's results in that source's own relevance order.
    static func rank(_ lists: [[Food]], query: String, weights: Weights = .standard, perSourceLimit: Int = 20) -> [Food] {
        let queryWords = FoodSearchText.words(query)
        guard !queryWords.isEmpty else { return lists.flatMap { $0 } }

        // Each name is folded and split once here, and reused for both the
        // score and the duplicate key.
        var scored: [(food: Food, score: Double, source: Int, position: Int, key: String)] = []
        for list in lists {
            for (position, food) in list.enumerated() {
                let alternatives = FoodSearchText.alternatives(folded: FoodSearchText.fold(food.name))
                let score = self.score(food, alternatives: alternatives,
                                       queryWords: queryWords, position: position, weights: weights)
                // "/()" aren't word characters, so the alternatives' words in
                // order are the name's words.
                let key = "\(alternatives.map(\.words).joined().joined(separator: " "))|\(FoodSearchText.words(food.brand ?? "").joined(separator: " "))"
                scored.append((food, score, sourceOrder(food.source), position, key))
            }
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.source != $1.source { return $0.source < $1.source }
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.food.id < $1.food.id
        }

        var seen = Set<String>()
        var perSource: [FoodSource: Int] = [:]
        var ranked: [Food] = []
        for entry in scored {
            let food = entry.food
            // Same id: a food this device materialised from a provider shows
            // up again as the user's own. Same name and brand: OFF lists one
            // product under several barcodes, and a food the user logged from
            // INDB comes back from the server under a new id. The first seen
            // is the higher-scored one, so the user's own copy wins.
            guard seen.insert("id:\(food.id)").inserted else { continue }
            guard seen.insert(entry.key).inserted else { continue }
            let count = perSource[food.source, default: 0]
            guard food.source == .local || count < perSourceLimit else { continue }
            perSource[food.source] = count + 1
            ranked.append(food)
        }
        return ranked
    }

    /// `rank`, on the global executor: results arrive on the main actor, and
    /// ranking ~100 names (~0.5 ms optimised, several in a debug build) has
    /// no reason to hold up a frame there.
    @concurrent
    static func rankedOffMain(_ lists: [[Food]], query: String) async -> [Food] {
        rank(lists, query: query)
    }

    static func score(_ food: Food, queryWords: [String], position: Int = 0, weights: Weights = .standard) -> Double {
        score(food, alternatives: FoodSearchText.alternatives(folded: FoodSearchText.fold(food.name)),
              queryWords: queryWords, position: position, weights: weights)
    }

    private static func score(_ food: Food, alternatives: [FoodSearchText.Alternative], queryWords: [String], position: Int, weights: Weights) -> Double {
        let (match, extraWords) = nameMatch(alternatives, queryWords: queryWords, weights: weights)
        var score = match
        score -= min(Double(extraWords) * weights.extraWordPenalty, weights.maxExtraWordPenalty)
        score -= Double(position) * weights.providerRankPenalty

        switch food.source {
        case .local: score += weights.personal
        case .indb: score += weights.indianDish + weights.curatedSource
        case .usda: score += weights.curatedSource
        case .openFoodFacts: score += weights.indiaProduct
        }
        if let variant = food.defaultVariant, variant.protein != nil, variant.carbs != nil, variant.fat != nil {
            score += weights.completeMacros
        }
        return score
    }

    /// The best match tier across the name's alternatives, and how many words
    /// that alternative has beyond the query's.
    private static func nameMatch(_ alternatives: [FoodSearchText.Alternative], queryWords: [String], weights: Weights) -> (score: Double, extraWords: Int) {
        var best: (score: Double, extraWords: Int) = (weights.noNameMatch, 0)
        let squashedQuery = queryWords.map(FoodSearchText.squash)
        for alternative in alternatives {
            let words = alternative.words
            let extra = max(0, alternative.headLength - queryWords.count)
            let tier: Double
            if words == queryWords {
                tier = weights.exactName
            } else if words.filter({ !weights.plainWords.contains($0) }) == queryWords {
                tier = weights.plainName
            } else if queryWords.allSatisfy(words.contains) {
                tier = queryWords.last == alternative.head ? weights.headNoun : weights.allWordsExact
            } else if queryWords.allSatisfy({ q in words.contains { $0.hasPrefix(q) } }) {
                tier = weights.allWordsPrefix
            } else {
                let squashed = words.map(FoodSearchText.squash)
                guard squashedQuery.allSatisfy({ q in squashed.contains { $0.hasPrefix(q) } }) else { continue }
                tier = weights.spellingVariant
            }
            // Plain qualifiers aren't "extra": "Rice, white, cooked" is rice.
            let penalised = tier == weights.plainName ? 0 : extra
            if tier > best.score || (tier == best.score && penalised < best.extraWords) {
                best = (tier, penalised)
            }
        }
        return best
    }

    /// Tie-break order only.
    private static func sourceOrder(_ source: FoodSource) -> Int {
        switch source {
        case .local: return 0
        case .indb: return 1
        case .usda: return 2
        case .openFoodFacts: return 3
        }
    }
}
