//
//  LocalAPIClient+Food.swift
//  SwiftSparkyFitness
//
//  Foods, food entries and exercise, backed by SwiftData.
//

import Foundation

extension LocalAPIClient {

    // MARK: - Mapping

    static func food(_ row: LocalFood) -> Food {
        Food(
            id: row.id,
            name: row.name,
            brand: row.brand,
            defaultVariant: FoodVariant(
                id: "\(row.id)-variant",
                servingSize: row.servingSize,
                servingUnit: row.servingUnit,
                calories: row.calories,
                protein: row.protein,
                carbs: row.carbs,
                fat: row.fat
            ),
            source: .local
        )
    }

    // MARK: - Food catalog

    /// Filtered in Swift rather than with a `#Predicate`: this is one person's
    /// own food list, and `localizedCaseInsensitiveContains` matches what a
    /// person expects from a search box far better than SwiftData's string
    /// predicates do for accented and cased text.
    /// ponytail: linear scan, fine for a personal catalogue; add a predicate
    /// and an index if anyone ever accumulates tens of thousands of foods.
    func searchFoods(query: String) async throws -> [Food] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return store.all(LocalFood.self)
            .filter { $0.name.localizedCaseInsensitiveContains(trimmed) || ($0.brand ?? "").localizedCaseInsensitiveContains(trimmed) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(Self.food)
    }

    /// The ranking the server normally does for us: recents by last use, top
    /// foods by how often they've been logged, both capped by the same
    /// `item_display_limit` preference the server reads before it answers.
    func foodSuggestions() async throws -> FoodSuggestions {
        let limit = max(1, store.all(LocalPreferences.self).first?.itemDisplayLimit ?? 10)
        let foods = store.all(LocalFood.self)

        let recents = foods
            .filter { $0.lastUsedAt != nil }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
            .prefix(limit)
            .map(Self.food)

        let top = foods
            .filter { $0.usageCount > 0 }
            .sorted { $0.usageCount > $1.usageCount }
            .prefix(limit)
            .map(Self.food)

        return FoodSuggestions(recentFoods: Array(recents), topFoods: Array(top))
    }

    /// OpenFoodFacts, called straight from the device. There is no server to
    /// proxy it in this mode, and unlike USDA it needs no API key.
    ///
    /// Two things verified against the live API rather than assumed:
    ///
    /// - The response is the same `products` shape the backend proxies, so
    ///   `OpenFoodFactsSearchResponse` decodes it unchanged — including its
    ///   per-product leniency, without which one malformed entry discards the
    ///   whole batch.
    /// - A **plain** decoder is mandatory. The shared one converts from
    ///   snake_case, which rewrites `product_name` to `productName` *before*
    ///   matching, so every field decodes as nil and search silently returns
    ///   nothing. That exact bug shipped once already; see
    ///   OpenFoodFactsProduct's header.
    ///
    /// The host answers an intermittent 503 (measured: roughly one request in
    /// four) with an HTML error page. That throws, which is correct — the food
    /// search UI already treats one source failing as a degrade rather than an
    /// error, as long as the other source still has results.
    func searchExternalFoods(query: String) async throws -> [Food] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl")!
        components.queryItems = [
            URLQueryItem(name: "search_terms", value: trimmed),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: "20"),
            // Asking for only the fields that are mapped keeps a search
            // response to a few KB instead of a few hundred.
            URLQueryItem(name: "fields", value: "code,brands,product_name,product_name_en,nutriments")
        ]
        guard let url = components.url else { throw APIError.invalidResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        // OpenFoodFacts asks identifying clients to name themselves, and
        // answers anonymous default-agent traffic less reliably.
        request.setValue("SwiftSparkyFitness/1.0 (iOS; local mode)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(
                message: "OpenFoodFacts is busy right now. Try again in a moment.",
                code: "OFF_\(http.statusCode)"
            )
        }

        let decoded = try JSONDecoder().decode(OpenFoodFactsSearchResponse.self, from: data)
        return decoded.products.compactMap(\.asFood)
    }

    /// Always empty: FoodData Central needs a per-account key that in server
    /// mode lives in the backend's provider table. Empty is the documented
    /// contract for "this server has no USDA provider configured", so callers
    /// already handle it as a quiet degrade rather than an error.
    func searchUsdaFoods(query: String) async throws -> [Food] {
        []
    }

    func createCustomFood(_ input: CustomFoodInput) async throws -> Food {
        let row = LocalFood(
            name: input.name,
            brand: input.brand,
            servingSize: input.servingSize,
            servingUnit: input.servingUnit,
            calories: input.calories,
            protein: input.protein,
            carbs: input.carbs,
            fat: input.fat,
            isCustom: true
        )
        store.insert(row)
        return Self.food(row)
    }

    /// Server mode has to persist an external result before it can be logged,
    /// because the `food_entries` insert policy requires a real `food_id`.
    /// Locally there's no such policy, but entries still reference a food by
    /// id, so the row has to exist either way.
    ///
    /// The provider's own id is reused as the local id, which makes this
    /// idempotent for free: logging the same product twice finds the row it
    /// made the first time instead of accumulating duplicates.
    func materializeExternalFood(_ food: Food) async throws -> Food {
        let id = food.id
        if let existing = store.fetch(LocalFood.self, where: #Predicate { $0.id == id }).first {
            return Self.food(existing)
        }
        guard let variant = food.defaultVariant else { throw APIError.invalidResponse }
        let row = LocalFood(
            id: id,
            name: food.name,
            brand: food.brand,
            servingSize: variant.servingSize ?? 100,
            servingUnit: variant.servingUnit ?? "g",
            calories: variant.calories ?? 0,
            protein: variant.protein ?? 0,
            carbs: variant.carbs ?? 0,
            fat: variant.fat ?? 0,
            isCustom: false
        )
        store.insert(row)
        return Self.food(row)
    }

    // MARK: - Food entries

    /// Scaled nutrition, matching `APIClient.foodEntryBody` exactly: the
    /// quantity is divided by the food's base serving and every macro
    /// multiplied through. Today, Diary and Progress all sum `entry.calories`
    /// straight from the row, so getting this wrong shows up as three screens
    /// quietly disagreeing with the food's own label.
    private func scaled(_ input: FoodEntryInput) -> (quantity: Double, unit: String, servingSize: Double, servingUnit: String, calories: Double, protein: Double, carbs: Double, fat: Double) {
        let variant = input.food.defaultVariant
        let baseServing = variant?.servingSize ?? 1
        let scale = baseServing > 0 ? input.quantity / baseServing : 1
        return (
            quantity: input.quantity,
            unit: variant?.servingUnit ?? "g",
            servingSize: baseServing,
            servingUnit: variant?.servingUnit ?? "g",
            calories: (variant?.calories ?? 0) * scale,
            protein: (variant?.protein ?? 0) * scale,
            carbs: (variant?.carbs ?? 0) * scale,
            fat: (variant?.fat ?? 0) * scale
        )
    }

    private func mealTypeName(_ id: String) -> String {
        store.fetch(LocalMealType.self, where: #Predicate { $0.id == id }).first?.name ?? ""
    }

    /// Logging a food is also what makes it "recent" — the server derives
    /// both lists from entry history, so local mode has to keep the same
    /// counters as it writes.
    private func markUsed(_ foodId: String) {
        guard let row = store.fetch(LocalFood.self, where: #Predicate { $0.id == foodId }).first else { return }
        row.lastUsedAt = Date()
        row.usageCount += 1
    }

    func createFoodEntry(_ input: FoodEntryInput) async throws {
        let values = scaled(input)
        store.insert(LocalFoodEntry(
            entryDate: input.entryDate,
            foodId: input.food.id,
            foodName: input.food.name,
            brandName: input.food.brand,
            mealTypeId: input.mealTypeId,
            mealTypeName: mealTypeName(input.mealTypeId),
            quantity: values.quantity,
            unit: values.unit,
            servingSize: values.servingSize,
            servingUnit: values.servingUnit,
            calories: values.calories,
            protein: values.protein,
            carbs: values.carbs,
            fat: values.fat
        ))
        markUsed(input.food.id)
        store.save()
    }

    func updateFoodEntry(id: String, _ input: FoodEntryInput) async throws {
        guard let row = store.fetch(LocalFoodEntry.self, where: #Predicate { $0.id == id }).first else {
            throw APIError.server(message: "That entry no longer exists.", code: nil)
        }
        let values = scaled(input)
        row.entryDate = input.entryDate
        row.dayKey = LocalDay.key(input.entryDate)
        row.foodId = input.food.id
        row.foodName = input.food.name
        row.brandName = input.food.brand
        row.mealTypeId = input.mealTypeId
        row.mealTypeName = mealTypeName(input.mealTypeId)
        row.quantity = values.quantity
        row.unit = values.unit
        row.servingSize = values.servingSize
        row.servingUnit = values.servingUnit
        row.calories = values.calories
        row.protein = values.protein
        row.carbs = values.carbs
        row.fat = values.fat
        store.save()
    }

    func deleteFoodEntry(id: String) async throws {
        guard let row = store.fetch(LocalFoodEntry.self, where: #Predicate { $0.id == id }).first else { return }
        store.delete(row)
    }

    // MARK: - Exercise

    /// The Health sentinel is excluded, which the server's own catalogue does
    /// by never containing it. `syncActiveEnergy` has to *create* an activity
    /// row to hang its entry off, so without this filter "Active Calories"
    /// became a searchable activity the moment Health synced once — and
    /// logging against it would then be read back as Health's own figure by
    /// `dailySummary`'s max(active, logged) rule.
    func searchExercises(query: String) async throws -> [Exercise] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let sentinel = ExerciseSessionSummary.healthActiveEnergyName
        return store.all(LocalExercise.self)
            .filter { $0.name != sentinel }
            .filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(LocalAPIClient.exercise)
    }

    /// Local mode's most-recently-logged distinct exercises — there is no
    /// server-side `usage_count` to rank by, so recency of the last entry
    /// stands in for it.
    func recentExercises() async throws -> [Exercise] {
        let sentinel = ExerciseSessionSummary.healthActiveEnergyName
        let recentIds = store.all(LocalExerciseEntry.self)
            .filter { $0.name != sentinel }
            .sorted { $0.entryDate > $1.entryDate }
            .map(\.exerciseId)
        var seen = Set<String>()
        let orderedIds = recentIds.filter { seen.insert($0).inserted }.prefix(10)
        let exercisesById = Dictionary(uniqueKeysWithValues: store.all(LocalExercise.self).map { ($0.id, $0) })
        return orderedIds.compactMap { exercisesById[$0] }.map(LocalAPIClient.exercise)
    }

    /// No server means no Free Exercise DB/Wger call — the same quiet
    /// degrade `searchUsdaFoods` already uses for "this deployment has no
    /// provider configured".
    func searchExternalExercises(query: String) async throws -> [ExternalExerciseResult] { [] }

    /// Never actually reached in local mode (searchExternalExercises always
    /// returns empty), but implemented honestly rather than left throwing —
    /// materializes straight into the local library, matching what the
    /// server's materialize call does.
    func materializeExternalExercise(_ result: ExternalExerciseResult) async throws -> Exercise {
        try await createCustomExercise(CustomExerciseInput(
            name: result.name, category: result.category ?? "Other",
            modality: result.modality ?? .duration,
            equipment: result.equipment, muscleGroups: result.primaryMuscles + result.secondaryMuscles,
            instructions: result.instructions
        ))
    }

    func createCustomExercise(_ input: CustomExerciseInput) async throws -> Exercise {
        let row = LocalExercise(name: input.name, category: input.category, modality: input.modality.rawValue)
        store.insert(row)
        return LocalAPIClient.exercise(row)
    }

    /// Matches on the whole name, case-insensitively, so logging "Running"
    /// twice reuses one activity instead of accumulating near-duplicates.
    func findOrCreateExercise(named name: String) async throws -> Exercise {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let existing = store.all(LocalExercise.self).first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return LocalAPIClient.exercise(existing)
        }
        let row = LocalExercise(name: trimmed, category: "Other")
        store.insert(row)
        return LocalAPIClient.exercise(row)
    }

    private static func setsJSON(_ sets: [ExerciseSetInput]) -> String? {
        guard !sets.isEmpty, let data = try? JSONEncoder().encode(sets) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func createExerciseEntry(_ input: ExerciseEntryInput) async throws -> ExerciseSessionSummary {
        let exerciseId = input.exerciseId
        let name = store.fetch(LocalExercise.self, where: #Predicate { $0.id == exerciseId }).first?.name ?? ""
        let row = LocalExerciseEntry(
            entryDate: input.entryDate,
            exerciseId: input.exerciseId,
            name: name,
            durationMinutes: input.durationMinutes ?? 0,
            caloriesBurned: input.caloriesBurned,
            modality: input.modality.rawValue,
            distance: input.distance,
            avgHeartRate: input.avgHeartRate,
            notes: input.notes,
            entryTime: input.entryTime,
            setsJSON: Self.setsJSON(input.sets)
        )
        store.insert(row)
        return LocalAPIClient.exerciseSummary(row)
    }

    func updateExerciseEntry(id: String, _ input: ExerciseEntryInput) async throws -> ExerciseSessionSummary {
        guard let row = store.fetch(LocalExerciseEntry.self, where: #Predicate { $0.id == id }).first else {
            throw APIError.server(message: "That entry no longer exists.", code: nil)
        }
        row.entryDate = input.entryDate
        row.dayKey = LocalDay.key(input.entryDate)
        let exerciseId = input.exerciseId
        row.exerciseId = exerciseId
        row.name = store.fetch(LocalExercise.self, where: #Predicate { $0.id == exerciseId }).first?.name ?? row.name
        row.durationMinutes = input.durationMinutes ?? 0
        row.caloriesBurned = input.caloriesBurned
        row.modality = input.modality.rawValue
        row.distance = input.distance
        row.avgHeartRate = input.avgHeartRate
        row.notes = input.notes
        row.entryTime = input.entryTime
        row.setsJSON = Self.setsJSON(input.sets)
        store.save()
        return LocalAPIClient.exerciseSummary(row)
    }

    func deleteExerciseEntry(id: String) async throws {
        guard let row = store.fetch(LocalExerciseEntry.self, where: #Predicate { $0.id == id }).first else { return }
        store.delete(row)
    }

    // MARK: - Health

    /// Upsert, never append. The server writes exactly one "Active Calories"
    /// row per day and rewrites it on each sync; appending instead would stack
    /// a new zero-minute row on every Today load and inflate the day's burn.
    ///
    /// The name has to be exactly this string — `isHealthActiveEnergy` matches
    /// on it to hide the row from Today and Diary, and `dailySummary`'s
    /// `max(active, logged)` rule reads it back through that same match.
    ///
    func syncActiveEnergy(kilocalories: Double, date: Date) async throws {
        let key = LocalDay.key(date)
        let name = ExerciseSessionSummary.healthActiveEnergyName
        if let existing = store.fetch(
            LocalExerciseEntry.self,
            where: #Predicate { $0.dayKey == key && $0.name == name }
        ).first {
            existing.caloriesBurned = kilocalories
            store.save()
            return
        }
        let exercise = try await findOrCreateExercise(named: name)
        store.insert(LocalExerciseEntry(
            entryDate: date,
            exerciseId: exercise.id,
            name: name,
            durationMinutes: 0,
            caloriesBurned: kilocalories
        ))
    }
}
