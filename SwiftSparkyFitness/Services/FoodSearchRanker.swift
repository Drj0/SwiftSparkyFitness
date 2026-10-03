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
//                    > all words > word prefixes > spelling variant > typo;
//                    a synonym ("dahi" for Curd) a little below the word
//  - personal        the user's own foods — they've logged them before
//  - Indian          INDB dishes, and OFF products (searched India-only)
//  - source quality  curated datasets over user-submitted barcodes
//  - completeness    all three macros present
//  - extra words     "Rice" beats "Rice flakes cutlet with mint chutney"
//  - provider rank   each provider's own relevance order, as a light nudge
//  - brand           brands most Indian households buy (PopularBrands), and
//                    brands this user logs often — a tie-breaker among equal
//                    name matches, never above a better one
//  - history         foods this user logs often or lately (History), so the
//                    order learns from the diary
//
//  When nothing holds every query word, the results holding most of them
//  are offered as closest matches; when only packaged products do, the
//  closest follow them.
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
            .map { singular($0) }
    }

    /// "rotis", "idlis", "eggs", "tomatoes", "curries" → roti, idli, egg,
    /// tomato, curry, on both the query and the names, so a plural typed or
    /// written still meets its singular. Leaves "hummus", "glass" and short
    /// words alone. On UTF-8 bytes: 115 = s, 101 = e, 105 = i, 111 = o,
    /// 117 = u, 99 = c, 104 = h, 120 = x, 121 = y.
    private static func singular(_ word: Substring.UTF8View.SubSequence) -> String {
        // Most words don't end in "s": no copy, no work.
        guard word.last == 115, word.count >= 4 else { return String(decoding: word, as: UTF8.self) }
        let bytes = Array(word)
        let n = bytes.count
        guard bytes[n - 2] != 115, bytes[n - 2] != 117 else {
            return String(decoding: bytes, as: UTF8.self)
        }
        var cut = n - 1
        if n >= 5, bytes[n - 2] == 101 {
            if bytes[n - 3] == 105 { return String(decoding: bytes[..<(n - 3)] + [121], as: UTF8.self) }  // -ies → -y
            if bytes[n - 3] == 111 || bytes[n - 3] == 120 || (bytes[n - 3] == 104 && (bytes[n - 4] == 99 || bytes[n - 4] == 115)) {
                cut = n - 2  // tomatoes, boxes, peaches, dishes
            }
        }
        return String(decoding: bytes[..<cut], as: UTF8.self)
    }

    /// Spelling-insensitive key: "channa" and "chana", "dhal" and "dal",
    /// "rajmah" and "rajma", "idly" and "idli" all meet. Doubled letters
    /// collapse, an `h` after a consonant drops, and a final `y` after one
    /// reads as `i` — the commonest variations in how Indian dish names get
    /// romanised. "ch" keeps its h ("chh" still folds to "ch"): read as "c",
    /// "chole" met "Coleslaw".
    static func squash(_ word: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(word.utf8.count)
        for byte in word.utf8 {
            if byte == out.last { continue }
            // "h" after an ASCII consonant other than c: 104 = h, 99 = c.
            if byte == 104, let last = out.last, last < 128, last != 99, !isVowel(last) { continue }
            out.append(byte)
        }
        // 121 = y, 105 = i.
        if out.count >= 3, out[out.count - 1] == 121, !isVowel(out[out.count - 2]) { out[out.count - 1] = 105 }
        return String(decoding: out, as: UTF8.self)
    }

    private static func isVowel(_ byte: UInt8) -> Bool {
        byte == 97 || byte == 101 || byte == 105 || byte == 111 || byte == 117  // a e i o u
    }

    /// Words that name the same food, as `words` leaves them (lowercased,
    /// singular): the Hindi and English names, and the commonest spellings
    /// squash doesn't already meet. "dahi" finds Curd rice and Amul's Curd,
    /// "chole" Chickpeas curry, "omlette" an omelette, "anda" an egg.
    /// Whole words only — a word still being typed matches as itself.
    private static let synonymGroups: [[String]] = [
        ["omelette", "omelet", "omlet", "omlette", "omelete", "amlet", "aamlet"],
        ["curd", "dahi", "yogurt", "yoghurt"],
        ["chana", "chole", "chhole", "channa", "chickpea"],
        ["egg", "anda", "ande", "anday"],
        ["potato", "aloo", "alu"],
        ["rice", "chawal"],
        ["chicken", "murgh", "murg"],
        ["milk", "doodh", "dudh"],
        ["tea", "chai"],
        ["lentil", "dal", "daal", "dhal"],
        ["banana", "kela", "kele"],
        ["mango", "aam"],
        ["spinach", "palak"],
        ["pea", "matar", "mutter"],
        ["cauliflower", "gobi", "gobhi"],
        ["okra", "bhindi", "ladyfinger"],
        ["eggplant", "brinjal", "baingan", "aubergine"],
        ["onion", "pyaz", "pyaaz", "kanda"],
        ["tomato", "tamatar"],
        ["cucumber", "kheera", "kakdi"],
        ["peanut", "groundnut", "moongphali", "mungfali"],
        ["laddu", "ladoo", "laddoo", "ladu"],
    ]

    /// Words that say how a dish is made rather than what it is: "chana
    /// masala" and "aloo sabzi" are chana and aloo dishes.
    static let dishStyleWords: Set<String> = [
        "masala", "curry", "sabzi", "sabji", "subzi", "fry", "gravy", "tadka", "tarka", "bhaji", "recipe",
    ]

    private static let synonymIndex: [String: [String]] = {
        var index: [String: [String]] = [:]
        for group in synonymGroups {
            for word in group { index[word] = group }
        }
        return index
    }()

    /// `word` and every word that names the same food, `word` first.
    static func synonyms(of word: String) -> [String] {
        guard let group = synonymIndex[word] else { return [word] }
        return [word] + group.filter { $0 != word }
    }

    /// The query as typed, then with each synonym in turn: "chole bhature" is
    /// also "chana bhature", "chickpea bhature"... Capped: a query is a few
    /// words, and at most one or two of them have synonyms.
    static func queryVariants(_ words: [String]) -> [[String]] {
        var variants = [words]
        for (index, word) in words.enumerated() {
            for synonym in synonyms(of: word).dropFirst() {
                for variant in variants where variant[index] == word {
                    var replaced = variant
                    replaced[index] = synonym
                    variants.append(replaced)
                    if variants.count >= 16 { return variants }
                }
            }
        }
        return variants
    }

    /// One slip of the finger apart — a letter missed, added, changed or two
    /// swapped — for words of five letters or more, where that can't turn
    /// one food into another ("omlette" is "omelette"; "rice" is not "mice").
    static func isOneTypoAway(_ word: String, _ typed: String) -> Bool {
        // Lengths first, without copying: most words are rejected here.
        let typedCount = typed.utf8.count
        guard typedCount >= 5, abs(word.utf8.count - typedCount) <= 1 else { return false }
        let a = Array(word.utf8), b = Array(typed.utf8)
        guard a != b else { return false }
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        if a.count == b.count {
            // A changed letter, or two swapped.
            if a[(i + 1)...] == b[(i + 1)...] { return true }
            return i + 1 < a.count && a[i] == b[i + 1] && a[i + 1] == b[i] && a[(i + 2)...] == b[(i + 2)...]
        }
        // A letter missed or added.
        let (longer, shorter) = a.count > b.count ? (a, b) : (b, a)
        return longer[(i + 1)...] == shorter[i...]
    }

    /// The query without the amount typed along with the food: "2 roti",
    /// "100g rice", "1 cup of dal" search for roti, rice, dal — and "bread
    /// slice", "pizza piece": a portion word after the food names how much,
    /// not what. Kept whole when that would leave almost nothing ("7 up",
    /// "123").
    static func searchText(_ query: String) -> String {
        var kept: [Substring] = []
        var afterAmount = false
        for chunk in query.split(whereSeparator: \.isWhitespace) {
            let lower = chunk.lowercased()
            let number = lower.prefix { $0.isNumber || $0 == "." || $0 == "/" }
            let rest = String(lower.dropFirst(number.count))
            if !number.isEmpty, rest.isEmpty || rest == "x" || quantityUnits.contains(rest) {
                afterAmount = true
                continue
            }
            if afterAmount, quantityUnits.contains(lower) || portionWords.contains(lower) || lower == "of" {
                continue
            }
            if !kept.isEmpty, lower != "x", portionWords.contains(lower) {
                continue
            }
            afterAmount = false
            kept.append(chunk)
        }
        let text = kept.joined(separator: " ")
        return text.filter(\.isLetter).count >= 3 ? text : query
    }

    private static let quantityUnits: Set<String> = [
        "g", "gm", "gms", "gram", "grams", "kg", "ml", "l", "ltr", "litre", "litres", "liter", "liters",
        "oz", "lb", "lbs", "kcal", "cal", "cals",
    ]
    private static let portionWords: Set<String> = [
        "x", "cup", "cups", "bowl", "bowls", "katori", "plate", "plates", "glass", "glasses", "piece", "pieces",
        "pc", "pcs", "slice", "slices", "tbsp", "tsp", "spoon", "spoons", "tablespoon", "teaspoon", "serving", "servings",
    ]

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

    /// A dish's names as written, for showing one of them. INDB packs several
    /// into one string: "Chapati/Roti", "Pea paneer curry (Matar paneer)",
    /// "Potato parantha/paratha (Aloo ka parantha/paratha)". A capitalised
    /// bracket or a slash before a capital (or a space) starts another name; a
    /// lowercase bracket is a qualifier that stays ("Lassi (salted)"); a slash
    /// inside a word is a spelling variant ("parantha/paratha").
    ///
    /// On UTF-8 bytes, like `tokens`: the Character-walking version was 10 µs
    /// a name, and every INDB result pays this on every ranking pass. INDB is
    /// ASCII; any other byte counts as neither upper- nor lowercase.
    static func nameAlternatives(_ name: String) -> [String] {
        // Most names hold nothing to split: 40 = "(", 47 = "/".
        guard name.utf8.contains(where: { $0 == 40 || $0 == 47 }) else { return [name] }
        let names = alternatives(of: Array(name.utf8)).map { String(decoding: $0, as: UTF8.self) }
        return names.isEmpty ? [name] : names
    }

    private typealias Bytes = [UInt8]

    // 32 = space, 40 = "(", 41 = ")", 47 = "/".
    private static func alternatives(of name: Bytes) -> [Bytes] {
        var text: Bytes = []
        var synonyms: [Bytes] = []
        var group: Bytes = []
        var depth = 0
        for byte in name {
            if byte == 40 {
                if depth > 0 { group.append(byte) }
                depth += 1
            } else if byte == 41, depth > 0 {
                depth -= 1
                if depth > 0 { group.append(byte); continue }
                let inner = trimmed(group)
                group = []
                if let first = inner.first, isLower(first) {
                    // "((Pattagobhi rolls)(curry))": the qualifier belongs to
                    // the name it follows.
                    if text.allSatisfy(isSpace), let last = synonyms.popLast() {
                        synonyms.append(last + [32, 40] + inner + [41])
                    } else {
                        text += [32, 40] + inner + [41]
                    }
                } else if !inner.isEmpty {
                    synonyms.append(inner)
                }
            } else if depth > 0 {
                group.append(byte)
            } else {
                text.append(byte)
            }
        }
        return wholeNames(text).flatMap(spellingVariants) + synonyms.flatMap { alternatives(of: $0) }
    }

    /// "Dahi bhaat/Dahi chawal/ Perugu annam" → three names. A slash between
    /// two single words is left for `spellingVariants`: "Suji/Rava idli" is
    /// Suji idli or Rava idli, "parantha/paratha" one word spelt two ways.
    private static func wholeNames(_ text: Bytes) -> [Bytes] {
        var names: [Bytes] = []
        var current: Bytes = []
        for index in text.indices {
            let byte = text[index]
            if byte == 47 {
                let next = index + 1 < text.count ? text[index + 1] : nil
                let spaced = (index > 0 && isSpace(text[index - 1])) || next.map(isSpace) ?? true
                let startsAPhrase = next.map(isUpper) == true && trimmed(current).contains(32)
                if spaced || startsAPhrase {
                    names.append(current)
                    current = []
                    continue
                }
            }
            current.append(byte)
        }
        names.append(current)
        return names
            .map { Bytes($0.split(whereSeparator: isSpace).joined(separator: [32])) }
            .filter { !$0.isEmpty }
    }

    /// "Potato parantha/paratha" → "Potato parantha", "Potato paratha".
    private static func spellingVariants(_ phrase: Bytes) -> [Bytes] {
        let words = phrase.split(separator: 32).map(Bytes.init)
        guard let index = words.firstIndex(where: { $0.contains(47) }) else { return [phrase] }
        return words[index].split(separator: 47).flatMap { option -> [Bytes] in
            var replaced = words
            replaced[index] = Bytes(option)
            return spellingVariants(Bytes(replaced.joined(separator: [32])))
        }
    }

    private static func trimmed(_ bytes: Bytes) -> Bytes {
        guard let first = bytes.firstIndex(where: { !isSpace($0) }),
              let last = bytes.lastIndex(where: { !isSpace($0) }) else { return [] }
        return Bytes(bytes[first...last])
    }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 }
    private static func isLower(_ byte: UInt8) -> Bool { byte >= 97 && byte <= 122 }
    private static func isUpper(_ byte: UInt8) -> Bool { byte >= 65 && byte <= 90 }

    /// The alternative names packed into one: INDB writes "Chapati/Roti" and
    /// "Kidney bean curry (Rajmah curry)"; USDA writes "Rice, white, cooked".
    /// Commas stay inside an alternative — they're qualifiers, not synonyms.
    /// `commaQualifies`: USDA's "Rice, white, cooked" is rice; INDB's
    /// "Paneer, apple and pineapple salad" is a salad.
    static func alternatives(folded name: String, commaQualifies: Bool = true) -> [Alternative] {
        name.utf8.split { $0 == 47 || $0 == 40 || $0 == 41 }  // / ( )
            .compactMap { part in
                let words = tokens(Substring(part))
                let beforeComma = commaQualifies
                    ? tokens(Substring(part.split(separator: 44, maxSplits: 1, omittingEmptySubsequences: false)[0]))  // ,
                    : words
                // "Paneer in butter sauce" is paneer; "Fish in coconut milk" is fish.
                let headWords = beforeComma.prefix { $0 != "with" && $0 != "in" }
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
        /// One typo in a long word ("omlette"), below every real match.
        var typo: Double = 22
        /// The same tiers through a synonym ("dahi" → Curd), a little below
        /// the word itself, so Amul's Dahi still leads for "dahi" — and never
        /// above `allWordsExact`, so "dal" lists the dals before USDA's
        /// "Lentils, NFS".
        var synonymPenalty: Double = 3
        /// The same tiers again on spelling-squashed words ("dhal" is "Mixed
        /// dal"'s head noun), a little below the real thing.
        var spellingPenalty: Double = 5
        /// Every query word is the brand's: "amul" → Amul's products. When
        /// the brand covers only some ("amul butter"), the rest must match
        /// the name, at that name's own tier.
        var brandOnly: Double = 40
        /// Nothing in the name or brand: the user's own foods keep it (the
        /// server matched them for a reason); a provider's result is dropped
        /// — "7 up" brought back baby formula.
        var noNameMatch: Double = 0
        /// Only when nothing holds every query word: results holding most of
        /// them ("paneer butter masala" → Paneer in butter sauce), scaled by
        /// the share matched and shown as closest matches, not as answers.
        var closestMatch: Double = 20

        /// Enough that the user's own food leads whenever its name holds
        /// every query word — but an exact canonical dish ("Chapati/Roti"
        /// for "roti") still beats their loosely matching "Roti wrap".
        var personal: Double = 70
        var indianDish: Double = 12
        var indiaProduct: Double = 4
        var curatedSource: Double = 8
        var completeMacros: Double = 4

        /// Brand priors: enough to reorder products whose names match equally
        /// (and to outweigh OFF's own order, up to 20 × 0.25), never enough
        /// to cross a name-match tier.
        var nationalBrand: Double = 5
        var regionalBrand: Double = 3
        /// A brand this user logs often, which beats the curated guess.
        var frequentBrand: Double = 8
        var maxBrandBonus: Double = 10
        /// The user's most-logged food; the rest of their top list scales
        /// down from it. Recent use adds a little on top.
        var frequentFood: Double = 12
        var recentFood: Double = 4

        var extraWordPenalty: Double = 2
        var maxExtraWordPenalty: Double = 16
        var providerRankPenalty: Double = 0.25

        /// Qualifiers that don't change what the food *is*.
        var plainWords: Set<String> = [
            "plain", "boiled", "cooked", "steamed", "raw", "fresh", "white", "whole", "homemade", "nfs",
            // How packaged staples are sold: "Toned Milk", "Classic Curd", "Low fat Dahi".
            "toned", "double", "skimmed", "skim", "uht", "pasteurised", "pasteurized", "homogenised",
            "homogenized", "standardised", "standardized", "classic", "regular", "low", "fat",
        ]

        static let standard = Weights()
    }

    /// Ranks results from several sources into one list. `lists` are each
    /// source's results in that source's own relevance order.
    /// What this user's diary says: the foods they log most and lately (the
    /// same lists the idle screen shows), and the brands of those foods.
    /// Built on device from `FoodSuggestions` in both modes.
    struct History {
        var foodBonus: [String: Double] = [:]
        var brandBonus: [String: Double] = [:]

        static let none = History()

        init() {}

        /// `topFoods` most-logged first.
        init(topFoods: [Food], recentFoods: [Food], weights: Weights = .standard) {
            let count = Double(max(topFoods.count, 1))
            for (index, food) in topFoods.enumerated() {
                let share = (count - Double(index)) / count
                foodBonus[food.id, default: 0] += weights.frequentFood * share
                for key in PopularBrands.keys(food.brand) {
                    brandBonus[key] = min(weights.frequentBrand, brandBonus[key, default: 0] + weights.frequentBrand * share)
                }
            }
            for food in recentFoods {
                foodBonus[food.id, default: 0] += weights.recentFood
            }
        }
    }

    struct Ranking {
        var foods: [Food]
        /// Nothing held every query word; `foods` hold most of them.
        var closestOnly = false
    }

    static func rank(_ lists: [[Food]], query: String, history: History = .none, weights: Weights = .standard, perSourceLimit: Int = 20) -> [Food] {
        ranking(lists, query: query, history: history, weights: weights, perSourceLimit: perSourceLimit).foods
    }

    static func ranking(_ lists: [[Food]], query: String, history: History = .none, weights: Weights = .standard, perSourceLimit: Int = 20) -> Ranking {
        let queryWords = FoodSearchText.words(query)
        guard !queryWords.isEmpty else { return Ranking(foods: lists.flatMap { $0 }) }
        let variants = FoodSearchText.queryVariants(queryWords)

        // Each name is folded and split once here, and reused for both the
        // score and the duplicate key.
        typealias Entry = (food: Food, score: Double, source: Int, position: Int, names: Names)
        var scored: [Entry] = []
        var closest: [Entry] = []
        var unmatched: [Entry] = []
        // Full matches that are dishes or foods, not packaged products.
        var foodMatches = 0
        // Most of a multi-word query: all but one word, at least one.
        let closestNeeds = max(1, queryWords.count - 1)
        // The last word is usually the dish ("chicken biryani"): with only
        // two words, it's the one that must be there — unless it only says
        // how the dish is made ("chana masala" is a chana dish).
        let dishWord = queryWords.count == 2 && FoodSearchText.dishStyleWords.contains(queryWords[1]) ? 0 : queryWords.count - 1
        for list in lists {
            for (position, food) in list.enumerated() {
                let names = Names(food)
                let (base, matched) = self.score(food, names: names, variants: variants, position: position, weights: weights)
                let bonus = personalBonus(food, brandKeys: names.brandKeys, history: history, weights: weights)
                if matched || food.source == .local {
                    scored.append((food, base + bonus, sourceOrder(food.source), position, names))
                    if matched, food.source != .openFoodFacts { foodMatches += 1 }
                } else if queryWords.count > 1 {
                    unmatched.append((food, base + bonus, sourceOrder(food.source), position, names))
                }
            }
        }
        // Closest matches never pad a list that has real ones — unless every
        // full match is a packaged product: one roasted-chana snack holding
        // "chana masala" mustn't hide the chickpea curries. Only worked out
        // when they'll be shown: it's the costly part of a ranking.
        if scored.isEmpty || foodMatches == 0 {
            // The dish word as the head ("chicken biryani" → Mutton
            // biryani), or for "chana masala" a curry.
            let styleOnly = dishWord != queryWords.count - 1
            let forms = queryWords.map { FoodSearchText.synonyms(of: $0) }
            let squashedForms = forms.map { $0.map(FoodSearchText.squash) }
            for entry in unmatched {
                let (held, holdsDish) = wordsHeld(entry.names, queryWords: queryWords, forms: forms,
                                                  squashedForms: squashedForms, dishWord: dishWord)
                guard held >= closestNeeds, holdsDish || queryWords.count > 2 else { continue }
                var share = weights.closestMatch * Double(held) / Double(queryWords.count)
                if entry.names.alternatives.contains(where: {
                    $0.head == queryWords[dishWord] || (styleOnly && FoodSearchText.dishStyleWords.contains($0.head))
                }) { share += weights.closestMatch / 2 }
                closest.append((entry.food, entry.score + share, entry.source, entry.position, entry.names))
            }
        }
        let order: (Entry, Entry) -> Bool = {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.source != $1.source { return $0.source < $1.source }
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.food.id < $1.food.id
        }
        scored.sort(by: order)
        closest.sort(by: order)
        let closestOnly = scored.isEmpty && !closest.isEmpty
        scored += closest

        var seen = Set<String>()
        var seenNames: [String: FoodSource] = [:]
        var perSource: [FoodSource: Int] = [:]
        var ranked: [Food] = []
        for entry in scored {
            let food = entry.food
            // Same id: a food this device materialised from a provider shows
            // up again as the user's own. Same name and brand: OFF lists one
            // product under several barcodes, and a food the user logged from
            // INDB comes back from the server under a new id. The first seen
            // is the higher-scored one, so the user's own copy wins.
            // An INDB dish is a duplicate under any of its names: the user
            // logged it as "Matar paneer", INDB calls it "Pea paneer curry
            // (Matar paneer)".
            // INDB's own rows are distinct dishes even when they share a
            // name: "Fruit salad" and "Frozen frosty fruit salad" are both
            // "Phalon ka salaad".
            guard seen.insert("id:\(food.id)").inserted else { continue }
            let keys = entry.names.keys()
            guard !keys.contains(where: { key in
                seenNames[key].map { $0 != .indb || food.source != .indb } ?? false
            }) else { continue }
            for key in keys where seenNames[key] == nil { seenNames[key] = food.source }
            let count = perSource[food.source, default: 0]
            guard food.source == .local || count < perSourceLimit else { continue }
            perSource[food.source] = count + 1
            ranked.append(entry.names.shown(for: food, variants: variants, weights: weights))
        }
        return Ranking(foods: ranked, closestOnly: closestOnly)
    }

    /// How many query words the name or brand holds, as a word or its start
    /// — spelt either way, as a synonym, or with one typo — and whether it
    /// holds the one at `dishWord`. `forms`: each query word's synonyms,
    /// worked out once per ranking.
    private static func wordsHeld(_ names: Names, queryWords: [String], forms: [[String]], squashedForms: [[String]],
                                  dishWord: Int) -> (count: Int, holdsDish: Bool) {
        let words = names.alternatives.flatMap(\.words) + names.brandKeys.flatMap { $0.split(separator: " ").map(String.init) }
        // Squashed only when a plain prefix misses, which is rare.
        var squashed: [String]?
        var count = 0
        var holdsDish = false
        for (index, q) in queryWords.enumerated() {
            var held = forms[index].contains { form in words.contains { $0.hasPrefix(form) } }
            if !held {
                let spelt = squashed ?? words.map(FoodSearchText.squash)
                squashed = spelt
                held = squashedForms[index].contains { form in spelt.contains { $0.hasPrefix(form) } }
                    || words.contains { FoodSearchText.isOneTypoAway($0, q) }
            }
            if held {
                count += 1
                if index == dishWord { holdsDish = true }
            }
        }
        return (count, holdsDish)
    }

    /// `rank`, on the global executor: results arrive on the main actor, and
    /// ranking ~100 names (~0.5 ms optimised, several in a debug build) has
    /// no reason to hold up a frame there.
    @concurrent
    static func rankedOffMain(_ lists: [[Food]], query: String, history: History = .none) async -> Ranking {
        ranking(lists, query: query, history: history)
    }

    /// Brand and history, kept apart from `score` because they aren't about
    /// the query. Brands count for providers' products only: the user's own
    /// food already carries `personal` and its own history.
    private static func personalBonus(_ food: Food, brandKeys keys: [String], history: History, weights: Weights) -> Double {
        var bonus = history.foodBonus[food.id] ?? 0
        if food.source != .local, !keys.isEmpty {
            let popular = keys.compactMap { PopularBrands.bonus[$0] }.max() ?? 0
            let mine = keys.compactMap { history.brandBonus[$0] }.max() ?? 0
            bonus += min(popular + mine, weights.maxBrandBonus)
        }
        return bonus
    }

    static func score(_ food: Food, queryWords: [String], position: Int = 0, weights: Weights = .standard) -> Double {
        score(food, names: Names(food), variants: FoodSearchText.queryVariants(queryWords), position: position, weights: weights).score
    }

    /// A food's name split into the names it goes by. Only INDB packs several
    /// into one string; other sources' brackets and slashes are part of a
    /// product name ("Paneer (Malai)") and are matched but never shortened.
    private struct Names {
        let written: [String]
        /// Per written name, its match alternatives.
        let parsed: [[FoodSearchText.Alternative]]
        /// The brand normalised once, for both the brand bonus and the
        /// duplicate key.
        let brandKeys: [String]
        /// Every alternative, plus — when there are several — all their
        /// words as one, so "roti chapati" still meets "Chapati/Roti" and
        /// "paneer malai" meets "Paneer (Malai)".
        let alternatives: [FoodSearchText.Alternative]

        init(_ food: Food) {
            written = food.source == .indb ? FoodSearchText.nameAlternatives(food.name) : [food.name]
            let commaQualifies = food.source != .indb
            parsed = written.map { FoodSearchText.alternatives(folded: FoodSearchText.fold($0), commaQualifies: commaQualifies) }
            brandKeys = PopularBrands.keys(food.brand)
            let all = parsed.flatMap { $0 }
            if all.count > 1, let first = all.first {
                let words = all.flatMap(\.words)
                alternatives = all + [FoodSearchText.Alternative(words: words, head: first.head, headLength: words.count)]
            } else {
                alternatives = all
            }
        }

        /// Duplicate keys: normalised name and brand, one per name.
        func keys() -> [String] {
            let brand = brandKeys.joined(separator: " ")
            // "/()" aren't word characters, so the alternatives' words in
            // order are the name's words.
            return parsed.map { "\($0.map(\.words).joined().joined(separator: " "))|\(brand)" }
        }

        /// The food as listed: an INDB dish under the one name that best
        /// matches the query — "Matar paneer", not "Pea paneer curry (Matar
        /// paneer)" — or its first name when none match. On a tie, the later
        /// name: INDB puts the Indian one in brackets, so "paneer" shows
        /// "Palak paneer" rather than "Spinach paneer". Logging saves the name
        /// shown, so the diary reads the same.
        func shown(for food: Food, variants: [[String]], weights: Weights) -> Food {
            guard written.count > 1 || written.first != food.name else { return food }
            let queryWords = variants[0]
            var best = 0
            var bestScore = -Double.infinity
            for (index, alternatives) in parsed.enumerated() {
                var score = nameMatch(alternatives, variants: variants, weights: weights).score
                // A closest match holds no name for the whole query; name it
                // by the dish word, the last one ("masala paneer" → Matar paneer).
                if score <= weights.noNameMatch, queryWords.count > 1, let last = queryWords.last {
                    score = nameMatch(alternatives, variants: FoodSearchText.queryVariants([last]), weights: weights).score
                }
                if score > bestScore || (score == bestScore && score > weights.noNameMatch) {
                    (best, bestScore) = (index, score)
                }
            }
            let name = written[best].prefix(1).uppercased() + written[best].dropFirst()
            return Food(id: food.id, name: name, brand: food.brand, defaultVariant: food.defaultVariant, source: food.source)
        }
    }

    private static func score(_ food: Food, names: Names, variants: [[String]], position: Int, weights: Weights) -> (score: Double, matched: Bool) {
        let queryWords = variants[0]
        var (match, extraWords) = nameMatch(names.alternatives, variants: variants, weights: weights)
        // Query words the brand accounts for: "amul butter" is Butter, Amul.
        if !names.brandKeys.isEmpty {
            let brandWords = Set(names.brandKeys.flatMap { $0.split(separator: " ").map(String.init) })
            let rest = queryWords.filter { !brandWords.contains($0) }
            if rest.count < queryWords.count {
                let viaBrand = rest.isEmpty
                    ? (score: weights.brandOnly, extraWords: 0)
                    : nameMatch(names.alternatives, queryWords: rest, weights: weights)
                if viaBrand.score > match { (match, extraWords) = viaBrand }
            }
        }
        let matched = match > weights.noNameMatch
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
        return (score, matched)
    }

    /// `nameMatch` for the query as typed or through a synonym, whichever
    /// matches best; a synonym's a little below the word itself.
    private static func nameMatch(_ alternatives: [FoodSearchText.Alternative], variants: [[String]], weights: Weights) -> (score: Double, extraWords: Int) {
        var best = nameMatch(alternatives, queryWords: variants[0], weights: weights)
        for queryWords in variants.dropFirst() {
            // Literal tiers only: a synonym spelt differently or mistyped
            // costs a pass per variant over every name, and buys nothing.
            // Most names hold no word of a variant at all; skip those first.
            guard queryWords.allSatisfy({ q in alternatives.contains { $0.words.contains { $0.hasPrefix(q) } } }) else { continue }
            var found = nameMatch(alternatives, queryWords: queryWords, weights: weights, fuzzy: false)
            guard found.score > weights.noNameMatch else { continue }
            found.score = max(min(found.score - weights.synonymPenalty, weights.allWordsExact), weights.typo)
            if found.score > best.score || (found.score == best.score && found.extraWords < best.extraWords) {
                best = found
            }
        }
        return best
    }

    /// The best match tier across the name's alternatives, and how many words
    /// that alternative has beyond the query's.
    private static func nameMatch(_ alternatives: [FoodSearchText.Alternative], queryWords: [String], weights: Weights,
                                  fuzzy: Bool = true) -> (score: Double, extraWords: Int) {
        var best: (score: Double, extraWords: Int) = (weights.noNameMatch, 0)
        var squashedQuery: [String]?
        for alternative in alternatives {
            let words = alternative.words
            let extra = max(0, alternative.headLength - queryWords.count)
            var found = tier(words, head: alternative.head, query: queryWords, plainWords: weights.plainWords, weights: weights)
            if found == nil, fuzzy {
                // Spelling: the same tiers on squashed words, so "dhal" meets
                // "Mixed dal" as its head noun rather than "Meetha daliya" by
                // prefix.
                let query = squashedQuery ?? queryWords.map(FoodSearchText.squash)
                squashedQuery = query
                if let spelt = tier(words.map(FoodSearchText.squash), head: FoodSearchText.squash(alternative.head),
                                    query: query, plainWords: squashedPlainWords(weights), weights: weights) {
                    found = (max(spelt.score - weights.spellingPenalty, weights.spellingVariant), spelt.plain)
                }
            }
            if found == nil, fuzzy, isTypoMatch(words, query: queryWords) {
                found = (weights.typo, false)
            }
            guard let (score, plain) = found else { continue }
            // Plain qualifiers aren't "extra": "Rice, white, cooked" is rice.
            let penalised = plain ? 0 : extra
            if score > best.score || (score == best.score && penalised < best.extraWords) {
                best = (score, penalised)
            }
        }
        return best
    }

    /// The best tier `words` reach for `query`, or nil. `plainWords` in the
    /// same form as `words` (squashed or not).
    private static func tier(_ words: [String], head: String, query: [String], plainWords: Set<String>,
                             weights: Weights) -> (score: Double, plain: Bool)? {
        if words == query { return (weights.exactName, false) }
        if words.filter({ !plainWords.contains($0) }) == query { return (weights.plainName, true) }
        if query.allSatisfy(words.contains) { return (query.last == head ? weights.headNoun : weights.allWordsExact, false) }
        if query.allSatisfy({ q in words.contains { $0.hasPrefix(q) } }) { return (weights.allWordsPrefix, false) }
        return nil
    }

    /// Every query word is a word of the name or its start, or one typo away
    /// from a word ("omlette" → Omelette), and at least one is the typo.
    private static func isTypoMatch(_ words: [String], query: [String]) -> Bool {
        var typos = 0
        for q in query {
            if words.contains(where: { $0.hasPrefix(q) }) { continue }
            guard words.contains(where: { FoodSearchText.isOneTypoAway($0, q) }) else { return false }
            typos += 1
        }
        return typos > 0
    }

    private static let standardSquashedPlainWords = Set(Weights.standard.plainWords.map(FoodSearchText.squash))

    private static func squashedPlainWords(_ weights: Weights) -> Set<String> {
        weights.plainWords == Weights.standard.plainWords
            ? standardSquashedPlainWords
            : Set(weights.plainWords.map(FoodSearchText.squash))
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
