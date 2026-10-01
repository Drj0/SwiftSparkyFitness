//
//  OpenFoodFactsSearch.swift
//  SwiftSparkyFitness
//
//  Packaged-food search against Open Food Facts' Search-a-licious service,
//  restricted to products sold in India, called straight from the device in
//  both modes.
//
//  Why not the old endpoints:
//  - `world.openfoodfacts.org/cgi/search.pl` (what local mode used) answered
//    503 to 6 of 10 back-to-back searches when measured; Search-a-licious
//    answered 10 of 10 in ~0.7 s.
//  - The server's `/api/foods/openfoodfacts/search` proxy uses
//    Search-a-licious too, but with no country filter, and makes a second
//    round trip to refresh every hit — slower, and "maggi" came back as
//    French stock cubes instead of the noodles.
//
//  OFF allows ~10 searches a minute per client and forbids search-as-you-type,
//  so FoodSearchViewModel only calls this after the debounce, for queries of
//  three or more characters, and caches answers for the life of the sheet.
//
//  Decoded with a *plain* JSONDecoder — see OpenFoodFactsProduct on why the
//  shared snake-case one silently empties every product.
//

import Foundation

enum OpenFoodFactsSearch {
    static let minimumQueryLength = 3

    static func request(for query: String) -> URLRequest? {
        // The query is Lucene syntax on the service side; a stray quote or
        // colon from the user would turn into a 400. Words are all it needs.
        let words = query.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : " " }
        let cleaned = String(words).split(separator: " ").joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }

        var components = URLComponents(string: "https://search.openfoodfacts.org/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "\(cleaned) countries_tags:\"en:india\""),
            URLQueryItem(name: "page_size", value: "20"),
            URLQueryItem(name: "langs", value: "en"),
            // Only the mapped fields: ~6 KB per search instead of ~200 KB.
            URLQueryItem(name: "fields", value: "code,brands,product_name,product_name_en,nutriments")
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // OFF asks clients to identify themselves and treats anonymous
        // default-agent traffic as a bot.
        request.setValue("SwiftSparkyFitness/1.1 (iOS)", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func foods(from data: Data) throws -> [Food] {
        try JSONDecoder().decode(OpenFoodFactsSearchResponse.self, from: data).products.compactMap(\.asFood)
    }

    static func search(_ query: String, session: URLSession = .shared) async throws -> [Food] {
        guard let request = request(for: query) else { return [] }
        var (data, response) = try await session.data(for: request)
        // One short retry absorbs the odd overloaded answer.
        if let http = response as? HTTPURLResponse, [429, 502, 503].contains(http.statusCode) {
            try await Task.sleep(nanoseconds: 700_000_000)
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(
                message: "Open Food Facts is busy right now. Try again in a moment.",
                code: "OFF_\(http.statusCode)"
            )
        }
        return try foods(from: data)
    }
}
