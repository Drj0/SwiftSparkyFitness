//
//  APIClient.swift
//  SwiftSparkyFitness
//
//  Pure networking layer — talks to the SparkyFitness backend directly
//  (bypasses the frontend's nginx; see docker-compose.yml's exposed
//  sparkyfitness-server port). No UI or app state lives here; that's the
//  ViewModel's job. Relies on URLSession's shared cookie jar to carry the
//  better-auth session cookie between requests — no manual token storage.
//
//  Every request/response shape here was verified against the live server,
//  not just the OpenAPI doc — the doc is stale in a few places (documented
//  next to the model that caught the mismatch).
//

import Foundation

extension Notification.Name {
    /// Posted whenever any request comes back 401 — the better-auth session
    /// cookie expired or was never valid. Every authenticated screen was
    /// otherwise showing this as its own generic "can't reach the server"
    /// error, which is confusing days into a session when it's really just
    /// "please sign in again." AuthViewModel listens and drops back to login.
    static let sessionExpired = Notification.Name("SparkyFitness.sessionExpired")
}

protocol APIClientProtocol {
    func signIn(email: String, password: String) async throws -> SessionUser
    func signUp(email: String, password: String) async throws -> SessionUser
    func currentSession() async throws -> SessionUser?
    func signOut() async
    func dailySummary(date: Date) async throws -> DailySummary
    func mealTypes() async throws -> [MealType]
    func searchFoods(query: String) async throws -> [Food]
    func searchExternalFoods(query: String) async throws -> [Food]
    func createCustomFood(_ input: CustomFoodInput) async throws -> Food
    func materializeExternalFood(_ food: Food) async throws -> Food
    func createFoodEntry(_ input: FoodEntryInput) async throws
    func updateFoodEntry(id: String, _ input: FoodEntryInput) async throws
    func deleteFoodEntry(id: String) async throws
    func searchExercises(query: String) async throws -> [Exercise]
    func findOrCreateExercise(named name: String) async throws -> Exercise
    func createExerciseEntry(_ input: ExerciseEntryInput) async throws -> ExerciseSessionSummary
    func updateExerciseEntry(id: String, _ input: ExerciseEntryInput) async throws -> ExerciseSessionSummary
    func deleteExerciseEntry(id: String) async throws
    func userPreferences() async throws -> UserPreferences
    func waterTotals(date: Date) async throws -> WaterTotals
    func waterLog(date: Date) async throws -> [WaterLogEntry]
    func adjustWater(date: Date, drinks: Int) async throws -> WaterTotals
    func logWaterAmount(date: Date, milliliters: Double) async throws -> WaterTotals
    func deleteWaterLogEntry(id: String) async throws
    func bodyMeasurements(date: Date) async throws -> BodyMeasurements
    func upsertBodyMeasurements(_ input: BodyMeasurementsInput) async throws -> BodyMeasurements
    func deleteBodyMeasurements(id: String) async throws
}

struct CustomFoodInput {
    let name: String
    let brand: String?
    let servingSize: Double
    let servingUnit: String
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
}

struct FoodEntryInput {
    let food: Food
    let mealTypeId: String
    let quantity: Double
    let entryDate: Date
}

struct ExerciseEntryInput {
    let exerciseId: String
    let durationMinutes: Double
    let caloriesBurned: Double
    let entryDate: Date
}

final class APIClient: APIClientProtocol {
    static let shared = APIClient()

    /// Read per request rather than captured once, so changing the address in
    /// Settings takes effect immediately instead of needing a relaunch.
    /// See ServerConfig for why this isn't a constant any more.
    var baseURL: URL { ServerConfig.url }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        // The default is 60s. Against a LAN-hosted backend that's indis-
        // tinguishable from a crash: every isSaving/isBusy gate would hold a
        // control disabled for a full minute with no way out. Perceived
        // performance is bounded by the worst case, so fail fast instead.
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()

    private struct ServerErrorBody: Decodable {
        let message: String?
        let error: String?
        let code: String?
    }

    /// Every non-2xx response funnels through here so a 401 is handled
    /// exactly once, everywhere, instead of each call site guessing at
    /// what a failure means.
    private func failure(status: Int, data: Data, fallback: String) -> APIError {
        let errBody = try? decoder.decode(ServerErrorBody.self, from: data)
        if status == 401 {
            NotificationCenter.default.post(name: .sessionExpired, object: nil)
        }
        return .server(message: errBody?.message ?? errBody?.error ?? fallback, code: errBody?.code)
    }

    /// Shared request path: builds the URL, JSON-encodes `body` if given,
    /// and either decodes `T` or throws an APIError carrying the server's
    /// message/code. Every JSON endpoint below goes through this.
    private func send<T: Decodable>(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Encodable? = nil
    ) async throws -> T {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }

        guard (200..<300).contains(http.statusCode) else {
            throw failure(status: http.statusCode, data: data, fallback: "Request failed (\(http.statusCode)).")
        }
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Auth

    private struct EmailPasswordRequest: Encodable {
        let email: String
        let password: String
    }

    private struct SignUpRequest: Encodable {
        let name: String
        let email: String
        let password: String
    }

    private struct AuthResponse: Decodable {
        let user: SessionUser
    }

    /// A stale session cookie left over from an invalidated session makes the
    /// server's CSRF/origin check reject a fresh sign-in with a raw "Missing
    /// or null Origin" error instead of just signing in — verified live.
    /// Starting every sign-in/sign-up with a clean cookie jar avoids that.
    /// Sweeps *every* cookie, not just the current host's. Matching on
    /// `baseURL.host` meant that changing the host (LAN IP → `.local`) left
    /// the previous host's cookies behind, and those were enough to trigger
    /// the very "Missing or null Origin" this exists to prevent — with no
    /// in-app recovery, since there's no sign-out. Verified live: the app
    /// could not sign in at all until it was deleted and reinstalled.
    /// `baseURL` is the only server this jar ever talks to, so there is
    /// nothing worth preserving here.
    private func clearStaleCookies() {
        guard let storage = session.configuration.httpCookieStorage else { return }
        storage.cookies?.forEach(storage.deleteCookie)
    }

    func signIn(email: String, password: String) async throws -> SessionUser {
        clearStaleCookies()
        return try await (send("api/auth/sign-in/email", method: "POST", body: EmailPasswordRequest(email: email, password: password)) as AuthResponse).user
    }

    func signUp(email: String, password: String) async throws -> SessionUser {
        clearStaleCookies()
        // The server's auth schema requires a display name; the sign-up
        // screen only collects email/password, so derive one from the email
        // rather than adding a field the design doesn't have.
        let name = email.split(separator: "@").first.map(String.init) ?? email
        return try await (send("api/auth/sign-up/email", method: "POST", body: SignUpRequest(name: name, email: email, password: password)) as AuthResponse).user
    }

    /// Throws on a transport failure; returns nil only when the server
    /// answered and there is genuinely no valid session.
    ///
    /// This used to be `try?`, which collapsed "the network is unreachable",
    /// "DNS failed", "the server 500'd" and "you are signed out" into a single
    /// nil — so a server outage silently dropped the user onto the Login
    /// screen with a valid session cookie still in hand and no explanation.
    /// Verified live: with the backend stopped, launching showed a bare login
    /// form. Distinguishing the two lets ContentView show an offline state
    /// with a Retry instead of a fake logout.
    /// Best-effort: tells the server to invalidate the session, then drops the
    /// cookie jar regardless. A failed round trip must still sign the user out
    /// locally — otherwise an unreachable server would trap them in the app.
    func signOut() async {
        _ = try? await (send("api/auth/sign-out") as MessageResponse)
        clearStaleCookies()
    }

    func currentSession() async throws -> SessionUser? {
        do {
            return try await (send("api/auth/get-session") as AuthResponse).user
        } catch let error as URLError {
            // Couldn't reach the server at all — the caller needs to know the
            // difference, so this is the one case that propagates.
            throw error
        } catch {
            // The server answered (a 401, or a body that isn't a session):
            // genuinely signed out.
            return nil
        }
    }

    // MARK: - Dashboard

    func dailySummary(date: Date) async throws -> DailySummary {
        try await send("api/daily-summary", query: [URLQueryItem(name: "date", value: dateFormatter.string(from: date))])
    }

    // MARK: - Meal types

    func mealTypes() async throws -> [MealType] {
        try await send("api/meal-types")
    }

    // MARK: - Food

    func searchFoods(query: String) async throws -> [Food] {
        let items = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "checkCustom", value: "true"),
            URLQueryItem(name: "broadMatch", value: "true"),
            URLQueryItem(name: "limit", value: "25"),
        ]
        return try await (send("api/foods", query: items) as FoodSearchResponse).searchResults
    }

    /// OpenFoodFacts is free/keyless and confirmed live — unlike USDA,
    /// Nutritionix, and Fatsecret, which this server also proxies but need
    /// per-provider API credentials configured server-side first.
    func searchExternalFoods(query: String) async throws -> [Food] {
        let response: OpenFoodFactsSearchResponse = try await send(
            "api/foods/openfoodfacts/search", query: [URLQueryItem(name: "query", value: query)]
        )
        return response.products.compactMap(\.asFood).prefix(20).map { $0 }
    }

    private struct CustomFoodRequest: Encodable {
        let name: String
        let brand: String?
        let isCustom = true
        let servingSize: Double
        let servingUnit: String
        let calories: Double
        let protein: Double
        let carbs: Double
        let fat: Double
    }

    func createCustomFood(_ input: CustomFoodInput) async throws -> Food {
        let body = CustomFoodRequest(
            name: input.name, brand: input.brand,
            servingSize: input.servingSize, servingUnit: input.servingUnit,
            calories: input.calories, protein: input.protein, carbs: input.carbs, fat: input.fat
        )
        return try await send("api/foods", method: "POST", body: body)
    }

    /// The food_entries insert RLS policy requires food_id to reference a
    /// real row in `foods` (or a valid meal_id) — verified against the
    /// policy source, and confirmed live: a snapshot-only insert with
    /// neither is rejected ("new row violates row-level security policy").
    /// So an OpenFoodFacts result has to be persisted as a real food first,
    /// exactly like "Enter food manually" — just auto-filled instead of typed.
    func materializeExternalFood(_ food: Food) async throws -> Food {
        guard let variant = food.defaultVariant else { throw APIError.invalidResponse }
        return try await createCustomFood(CustomFoodInput(
            name: food.name, brand: food.brand,
            servingSize: variant.servingSize ?? 100, servingUnit: variant.servingUnit ?? "g",
            calories: variant.calories ?? 0, protein: variant.protein ?? 0,
            carbs: variant.carbs ?? 0, fat: variant.fat ?? 0
        ))
    }

    private struct FoodEntryRequest: Encodable {
        let mealTypeId: String
        let foodId: String
        let variantId: String?
        let foodName: String
        let quantity: Double
        let unit: String
        let entryDate: String
        let calories: Double
        let protein: Double?
        let carbs: Double?
        let fat: Double?
    }

    private func foodEntryBody(_ input: FoodEntryInput) -> FoodEntryRequest {
        let variant = input.food.defaultVariant
        let baseServing = variant?.servingSize ?? 1
        let scale = baseServing > 0 ? input.quantity / baseServing : 1
        return FoodEntryRequest(
            mealTypeId: input.mealTypeId,
            foodId: input.food.id,
            variantId: variant?.id,
            foodName: input.food.name,
            quantity: input.quantity,
            unit: variant?.servingUnit ?? "g",
            entryDate: dateFormatter.string(from: input.entryDate),
            calories: (variant?.calories ?? 0) * scale,
            protein: variant?.protein.map { $0 * scale },
            carbs: variant?.carbs.map { $0 * scale },
            fat: variant?.fat.map { $0 * scale }
        )
    }

    /// The create/update response is the raw `food_entries` row, which
    /// (verified live) has `meal_type_id` but never the plain `meal_type`
    /// string `FoodEntrySummary.mealType` requires — that convenience field
    /// only exists on entries nested inside GET /api/daily-summary, a
    /// different serializer. Decoding this response as `FoodEntrySummary`
    /// throws ("data couldn't be read because it is missing", confirmed
    /// live via Diary's edit flow). Neither caller uses the returned row —
    /// this decodes just enough to confirm success, and discards the rest,
    /// the same way exercise-entries' create/update already do.
    private struct FoodEntryAck: Decodable { let id: String }

    /// `input.food` must already be a real, locally-persisted food (a plain
    /// search result, or the output of materializeExternalFood) — its id and
    /// variant id are what the RLS policy checks against.
    func createFoodEntry(_ input: FoodEntryInput) async throws {
        let _: FoodEntryAck = try await send("api/food-entries", method: "POST", body: foodEntryBody(input))
    }

    private struct MessageResponse: Decodable { let message: String? }

    /// Same body shape as create — verified live: PUT accepts a partial
    /// update (quantity/calories/macros), returning the full updated row.
    func updateFoodEntry(id: String, _ input: FoodEntryInput) async throws {
        let _: FoodEntryAck = try await send("api/food-entries/\(id)", method: "PUT", body: foodEntryBody(input))
    }

    func deleteFoodEntry(id: String) async throws {
        _ = try await (send("api/food-entries/\(id)", method: "DELETE") as MessageResponse)
    }

    // MARK: - Exercise

    func searchExercises(query: String) async throws -> [Exercise] {
        try await send("api/exercises/search", query: [URLQueryItem(name: "searchTerm", value: query)])
    }

    /// Exercise creation is multipart on this API (a JSON string field
    /// inside form-data, not a JSON body) — verified live, the plain-JSON
    /// POST /exercises/ the doc implies returns "Invalid exercise payload."
    func findOrCreateExercise(named name: String) async throws -> Exercise {
        let matches = try await searchExercises(query: name)
        if let existing = matches.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: baseURL.appendingPathComponent("api/exercises/"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let payload = try encoder.encode(["name": name, "category": "Other", "source": "manual"])
        var body = Data()
        // ASCII literals encode to UTF-8 unconditionally; these can't fail.
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"exerciseData\"\r\n\r\n".utf8))
        body.append(payload)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw failure(status: http.statusCode, data: data, fallback: "Couldn't save that activity.")
        }
        return try decoder.decode(Exercise.self, from: data)
    }

    private struct ExerciseEntryRequest: Encodable {
        let exerciseId: String
        let entryDate: String
        let durationMinutes: Double
        let caloriesBurned: Double
    }

    func createExerciseEntry(_ input: ExerciseEntryInput) async throws -> ExerciseSessionSummary {
        let body = ExerciseEntryRequest(
            exerciseId: input.exerciseId,
            entryDate: dateFormatter.string(from: input.entryDate),
            durationMinutes: input.durationMinutes,
            caloriesBurned: input.caloriesBurned
        )
        struct CreatedEntry: Decodable {
            let id: String
            let exerciseName: String?
            let caloriesBurned: Double?
            let durationMinutes: Double?
        }
        let created: CreatedEntry = try await send("api/exercise-entries", method: "POST", body: body)
        return ExerciseSessionSummary(
            id: created.id, name: created.exerciseName,
            caloriesBurned: created.caloriesBurned, durationMinutes: created.durationMinutes,
            exerciseId: input.exerciseId
        )
    }

    func updateExerciseEntry(id: String, _ input: ExerciseEntryInput) async throws -> ExerciseSessionSummary {
        let body = ExerciseEntryRequest(
            exerciseId: input.exerciseId,
            entryDate: dateFormatter.string(from: input.entryDate),
            durationMinutes: input.durationMinutes,
            caloriesBurned: input.caloriesBurned
        )
        struct UpdatedEntry: Decodable {
            let id: String
            let exerciseName: String?
            let caloriesBurned: Double?
            let durationMinutes: Double?
        }
        let updated: UpdatedEntry = try await send("api/exercise-entries/\(id)", method: "PUT", body: body)
        return ExerciseSessionSummary(
            id: updated.id, name: updated.exerciseName,
            caloriesBurned: updated.caloriesBurned, durationMinutes: updated.durationMinutes,
            exerciseId: input.exerciseId
        )
    }

    func deleteExerciseEntry(id: String) async throws {
        _ = try await (send("api/exercise-entries/\(id)", method: "DELETE") as MessageResponse)
    }

    // MARK: - Preferences

    /// Source of truth for the weight/measurement/water units the UI labels
    /// its fields with — nothing unit-related is hardcoded in the app. See
    /// UserPreferences for why no conversion happens on top of this.
    func userPreferences() async throws -> UserPreferences {
        try await send("api/user-preferences")
    }

    // MARK: - Water

    /// Water lives under the `/api/v2` prefix — the one Module 3 missed when
    /// it concluded there was no per-entry water API. The v1
    /// `/api/measurements/water-intake` routes still exist and behave
    /// identically for the total/quick-add (confirmed live, both used by the
    /// reference web client), but only v2 exposes the itemised log.
    private func waterPath(_ suffix: String) -> String {
        "api/v2/measurements/water-intake\(suffix)"
    }

    func waterTotals(date: Date) async throws -> WaterTotals {
        try await send(waterPath("/\(dateFormatter.string(from: date))"))
    }

    /// The itemised ledger for a day, newest first (the server's own order).
    func waterLog(date: Date) async throws -> [WaterLogEntry] {
        try await send(waterPath("/\(dateFormatter.string(from: date))/log"))
    }

    private struct WaterIntakeRequest: Encodable {
        let entryDate: String
        let changeDrinks: Int
        let containerId: Int?
    }

    /// Quick-add / undo. A positive count inserts that many ledger rows; a
    /// negative one deletes that many of the most recent *manual* rows,
    /// which is the backend's own undo. Verified live that it clamps at zero
    /// rather than going negative, and that decrementing an empty day is a
    /// harmless no-op — so the UI doesn't have to pre-check.
    func adjustWater(date: Date, drinks: Int) async throws -> WaterTotals {
        try await adjustWater(date: date, drinks: drinks, containerId: nil)
    }

    private func adjustWater(date: Date, drinks: Int, containerId: Int?) async throws -> WaterTotals {
        let clamped = max(-Water.maxDrinksPerRequest, min(Water.maxDrinksPerRequest, drinks))
        return try await send(
            waterPath(""), method: "POST",
            body: WaterIntakeRequest(
                entryDate: dateFormatter.string(from: date),
                changeDrinks: clamped,
                containerId: containerId
            )
        )
    }

    private struct WaterContainerRequest: Encodable {
        let name: String
        let volume: Double
        let unit = "ml"
        let servingsPerContainer = 1
    }

    private struct WaterContainerResponse: Decodable { let id: Int }

    /// Logs an exact amount of water.
    ///
    /// The backend has no raw-millilitre manual write: a drink is always
    /// `container volume ÷ servings`, and the only other candidate —
    /// `PUT /water-intake/{id}` — overwrites the daily *aggregate*, which
    /// the server recomputes from the ledger on the very next quick-add,
    /// silently discarding it (read in recomputeWaterAggregateForUser,
    /// confirmed live). So an exact amount is logged through a container
    /// that exists only for the length of this call.
    ///
    /// This is safe because the ledger row snapshots both the millilitres
    /// and the container's name at insert time: verified live end-to-end —
    /// 300 ml survived the container's deletion, stayed 300 ml through a
    /// later +250 quick-add's recompute, and left the user's container list
    /// empty afterwards. The container is torn down even if the drink fails,
    /// so a mid-flight error can't leave one behind.
    func logWaterAmount(date: Date, milliliters: Double) async throws -> WaterTotals {
        let container: WaterContainerResponse = try await send(
            "api/water-containers", method: "POST",
            body: WaterContainerRequest(name: "Custom amount", volume: milliliters)
        )
        do {
            let totals = try await adjustWater(date: date, drinks: 1, containerId: container.id)
            try? await deleteWaterContainer(id: container.id)
            return totals
        } catch {
            try? await deleteWaterContainer(id: container.id)
            throw error
        }
    }

    private func deleteWaterContainer(id: Int) async throws {
        _ = try await (send("api/water-containers/\(id)", method: "DELETE") as MessageResponse)
    }

    func deleteWaterLogEntry(id: String) async throws {
        _ = try await (send(waterPath("/log/\(id)"), method: "DELETE") as MessageResponse)
    }

    // MARK: - Weight & body measurements (the backend's "check-in")

    /// A day's check-in row, or `BodyMeasurements.none` when nothing is
    /// logged — the server answers `{}` in that case, which decodes into
    /// all-nil fields rather than failing or 404ing.
    func bodyMeasurements(date: Date) async throws -> BodyMeasurements {
        try await send("api/measurements/check-in/\(dateFormatter.string(from: date))")
    }

    /// Upsert keyed by (user, date) — there's no create/update distinction to
    /// make, and no way to end up with two weights on one day. Only the
    /// fields in `input` are written.
    func upsertBodyMeasurements(_ input: BodyMeasurementsInput) async throws -> BodyMeasurements {
        // A body with no measurement keys is the one case the server answers
        // with a literal `null` (it has nothing to upsert), which wouldn't
        // decode. Callers validate before saving, so this is a guard against
        // a future caller, not a reachable state today.
        guard !input.values.isEmpty else { throw APIError.invalidResponse }
        return try await send("api/measurements/check-in", method: "POST", body: input)
    }

    func deleteBodyMeasurements(id: String) async throws {
        _ = try await (send("api/measurements/check-in/\(id)", method: "DELETE") as MessageResponse)
    }
}
