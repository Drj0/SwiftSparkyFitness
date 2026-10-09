//
//  LocalAPIClient.swift
//  SwiftSparkyFitness
//
//  The local-only implementation of `APIClientProtocol`.
//
//  Why this conforms to the existing 46-method protocol rather than a new set
//  of domain repositories: all 14 view models already take `APIClientProtocol`
//  by injection, and the test target's `StubAPIClient` has implemented the same
//  protocol in memory across eight modules and 100+ tests. The seam is proven.
//  Splitting into repositories would have rewritten every view model's init and
//  every test wiring site for no behavioural gain, and `dailySummary` spans
//  food, exercise, water and goals, so a split would need a cross-domain facade
//  that ends up looking exactly like this protocol again.
//
//  The cost is a handful of methods that mean nothing without a server. They
//  are implemented honestly — a no-op where that's the truth, a thrown error
//  where silence would hide a bug — rather than left to fatalError.
//
//  Split across extensions by domain (see LocalAPIClient+Food /
//  +Wellbeing) purely so the file stays readable.
//

import Foundation

@MainActor
final class LocalAPIClient: APIClientProtocol {
    static let shared = LocalAPIClient()

    let store: LocalStore

    init(store: LocalStore = .shared) {
        self.store = store
    }

    /// When local mode was first used. Load-bearing rather than decorative:
    /// Diary's day navigation and Progress's range both floor on the account's
    /// creation date, so without a stable value here the user could page back
    /// through unlimited empty days.
    static let firstUseKey = "localModeFirstUse"

    /// Never later than the first day the diary has anything on: a diary
    /// that came back from iCloud after a reinstall, or from another
    /// device, is older than this install, and floored at the install date
    /// all of it was unreachable from Today and Diary.
    var firstUseDate: Date {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: Self.firstUseKey) as? Date
        var start = stored ?? Calendar.current.startOfDay(for: Date())
        if let earliest = store.earliestEntryDay() { start = min(start, earliest) }
        if start != stored { defaults.set(start, forKey: Self.firstUseKey) }
        return start
    }

    /// Thrown by the few endpoints that can only mean something against a
    /// server. Never expected to surface: local mode doesn't show the screens
    /// that would call them.
    func unsupported(_ what: String) -> APIError {
        .server(message: "\(what) isn't available without a server.", code: "LOCAL_MODE")
    }

    // MARK: - Auth (bypassed)

    /// Local mode has no account, so there is always a "session". Returning a
    /// synthetic user is what keeps `ContentView` out of the login branch
    /// without teaching it a second way to decide it's signed in.
    func currentSession() async throws -> SessionUser? {
        SessionUser(email: "On this device", name: nil, createdAt: firstUseDate)
    }

    func signIn(email: String, password: String) async throws -> SessionUser {
        throw unsupported("Signing in")
    }

    func signUp(email: String, password: String) async throws -> SessionUser {
        throw unsupported("Signing up")
    }

    func requestPasswordReset(email: String) async throws {
        throw unsupported("Password reset")
    }

    /// Nothing to sign out of, and deliberately not a data wipe — leaving local
    /// mode must never be the thing that deletes the diary. Settings has an
    /// explicit, separately confirmed control for that.
    func signOut() async {}

    // MARK: - Meal types

    /// One per id: two devices each seed the four defaults before iCloud
    /// meets them, and an exact tie between those copies isn't deleted (see
    /// `LocalStore.removeDuplicateRows`), so it's hidden here — newest first.
    func mealTypes() async throws -> [MealType] {
        var seen: Set<String> = []
        return store.all(LocalMealType.self, sortBy: [SortDescriptor(\.sortOrder)])
            .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.updatedAt > $1.updatedAt }
            .filter { seen.insert($0.id).inserted }
            .map(Self.mealType)
    }

    static func mealType(_ row: LocalMealType) -> MealType {
        MealType(
            id: row.id,
            name: row.name,
            sortOrder: row.sortOrder,
            // A nil userId is what marks a row as one of the protected
            // defaults, matching the server's shared-row convention that
            // `isSystemDefault` already reads.
            userId: row.isSystemDefault ? nil : "local",
            isVisible: row.isVisible,
            showInQuickLog: nil,
            defaultTime: row.defaultTime
        )
    }

    func createMealType(name: String, sortOrder: Int) async throws -> MealType {
        let row = LocalMealType(name: name, sortOrder: sortOrder, isSystemDefault: false)
        store.insert(row)
        return Self.mealType(row)
    }

    func updateMealType(id: String, _ input: MealTypeInput) async throws -> MealType {
        guard let row = store.fetch(LocalMealType.self, where: #Predicate { $0.id == id }).first else {
            throw unsupported("That meal")
        }
        // The server refuses to rename or reorder its own four, and the
        // management screen is built around that refusal. Local mode keeps the
        // same rule so the two modes don't disagree about what's editable.
        if row.isSystemDefault, input.name != nil || input.sortOrder != nil {
            throw APIError.server(message: "Cannot rename or reorder system default meal types.", code: nil)
        }
        if let name = input.name {
            row.name = name
            // Entries carry the meal's name denormalised, because that is the
            // shape the day screens group on. Renaming the category alone
            // left every row already logged against it grouped under the old
            // name until it was re-saved.
            for entry in store.fetch(LocalFoodEntry.self, where: #Predicate { $0.mealTypeId == id }) {
                entry.mealTypeName = name
            }
        }
        if let sortOrder = input.sortOrder { row.sortOrder = sortOrder }
        if let isVisible = input.isVisible { row.isVisible = isVisible }
        if let defaultTime = input.defaultTime { row.defaultTime = defaultTime }
        store.save()
        return Self.mealType(row)
    }

    func deleteMealType(id: String) async throws {
        guard let row = store.fetch(LocalMealType.self, where: #Predicate { $0.id == id }).first else { return }
        if row.isSystemDefault {
            throw APIError.server(message: "Cannot delete system default meal types.", code: nil)
        }
        // The server answers 409 rather than orphaning the entries; without the
        // same check here, deleting a meal would strand every row logged to it.
        let inUse = store.fetch(LocalFoodEntry.self, where: #Predicate { $0.mealTypeId == id })
        guard inUse.isEmpty else {
            throw APIError.server(
                message: "That meal still has food logged against it. Move or delete those entries first.",
                code: "IN_USE"
            )
        }
        store.delete(row)
    }

    // MARK: - Preferences

    func userPreferences() async throws -> UserPreferences {
        Self.preferences(store.all(LocalPreferences.self).first)
    }

    static func preferences(_ row: LocalPreferences?) -> UserPreferences {
        UserPreferences(
            defaultWeightUnit: row?.defaultWeightUnit,
            defaultMeasurementUnit: row?.defaultMeasurementUnit,
            waterDisplayUnit: row?.waterDisplayUnit,
            measurementDecimalPlaces: row?.measurementDecimalPlaces,
            defaultDistanceUnit: row?.defaultDistanceUnit,
            activityLevel: row?.activityLevel,
            exerciseCaloriePercentage: row?.exerciseCaloriePercentage
        )
    }

    func updateUserPreference(_ setting: UserPreferences.Setting, to value: String) async throws -> UserPreferences {
        let row = store.all(LocalPreferences.self).first ?? {
            let fresh = LocalPreferences()
            store.insert(fresh)
            return fresh
        }()
        let before = Self.preferences(row)
        Self.apply(setting, value, to: row)
        Self.convertStoredUnits(from: before, to: Self.preferences(row), in: store)
        store.save()
        return try await userPreferences()
    }

    func profile() async throws -> UserProfile {
        Self.profile(store.all(LocalPreferences.self).first)
    }

    static func profile(_ row: LocalPreferences?) -> UserProfile {
        UserProfile(
            sex: row?.sex.flatMap(UserProfile.Sex.init(rawValue:)),
            birthDate: row?.birthDate,
            primaryGoal: row?.primaryGoal.flatMap(UserProfile.PrimaryGoal.init(rawValue:)),
            targetWeight: row?.targetWeight
        )
    }

    func saveProfile(_ profile: UserProfile) async throws {
        let row = store.all(LocalPreferences.self).first ?? {
            let fresh = LocalPreferences()
            store.insert(fresh)
            return fresh
        }()
        row.sex = profile.sex?.rawValue
        row.birthDate = profile.birthDate
        row.primaryGoal = profile.primaryGoal?.rawValue
        row.targetWeight = profile.targetWeight
        store.save()
    }

    /// A kg/lb or cm/in switch rewrites every stored weight or length in the
    /// new unit. Relabelling instead would change what they mean to the
    /// server, which keeps metric (see UserPreferences.metricFactor).
    /// Shared with the server pull, for a switch made on the web.
    static func convertStoredUnits(from old: UserPreferences, to new: UserPreferences, in store: LocalStore) {
        let changed = [BodyField.UnitKind.weight, .length].filter { old.metricFactor($0) != new.metricFactor($0) }
        guard !changed.isEmpty else { return }
        for row in store.all(LocalCheckIn.self) {
            for field in BodyField.allCases where changed.contains(field.unitKind) {
                if let value = measurements(row).value(for: field) {
                    set(field, new.fromMetric(old.toMetric(value, field.unitKind), field.unitKind), on: row)
                }
            }
        }
        if changed.contains(.weight), let prefs = store.all(LocalPreferences.self).first, let target = prefs.targetWeight {
            prefs.targetWeight = new.fromMetric(old.toMetric(target, .weight), .weight)
        }
    }

    /// Shared with the server pull, which writes preferences it received.
    static func apply(_ setting: UserPreferences.Setting, _ value: String, to row: LocalPreferences) {
        switch setting {
        case .weight: row.defaultWeightUnit = value
        case .measurement: row.defaultMeasurementUnit = value
        case .water: row.waterDisplayUnit = value
        case .decimals: row.measurementDecimalPlaces = Int(value) ?? 0
        case .distance: row.defaultDistanceUnit = value
        case .activityLevel: row.activityLevel = value
        case .exerciseCaloriePercentage: row.exerciseCaloriePercentage = Double(value) ?? 100
        }
    }

    // MARK: - The day

    /// Assembles the same shape `GET /api/daily-summary` returns.
    ///
    /// Two of its numbers are the ones the server actually computes, and both
    /// are reproduced deliberately:
    ///
    /// - `burned` is Health's active energy plus the exercise you logged that
    ///   it doesn't already contain (`dayBurn`). Active energy includes every
    ///   Health workout, so imported workouts, and hand-logged entries that
    ///   match one by time, aren't added on top. The server itself takes
    ///   `max(active, logged)`; this app shows its own, finer figure.
    /// - `goal` falls back to 2000 when no goal row exists, which is what the
    ///   server substitutes. It is kept distinct from `goals.calories`, which
    ///   stays nil — the goal-not-set card reads the latter, and collapsing the
    ///   two is exactly the bug that made that card unreachable in Module 2.
    func dailySummary(date: Date) async throws -> DailySummary {
        let key = LocalDay.key(date)
        let foodRows = store.fetch(LocalFoodEntry.self, where: #Predicate { $0.dayKey == key })
        let exerciseRows = store.fetch(LocalExerciseEntry.self, where: #Predicate { $0.dayKey == key })
        let waterRows = store.fetch(LocalWaterEntry.self, where: #Predicate { $0.dayKey == key })

        let goals = try await goals(date: date)
        let entries = foodRows.map(Self.foodEntrySummary)
        let sessions = exerciseRows.map(Self.exerciseSummary).markingHealthDuplicates()
        let burned = sessions.dayBurn

        let eaten = entries.reduce(0.0) { $0 + $1.calories }
        let goalCalories = goals.calories.flatMap { $0 > 0 ? $0 : nil } ?? 2000

        let manual = waterRows.filter { $0.source == "manual" }.reduce(0.0) { $0 + $1.waterMl }
        let ledger = waterRows.reduce(0.0) { $0 + $1.waterMl }

        return DailySummary(
            calorieBalance: .init(
                eaten: eaten,
                burned: burned,
                remaining: goalCalories - eaten + burned,
                goal: goalCalories
            ),
            waterIntake: ledger,
            waterIntakeBreakdown: WaterTotals(
                waterMl: ledger,
                manualMl: manual,
                ledgerMl: ledger,
                foodMl: 0
            ),
            goals: .init(
                calories: goals.calories,
                protein: goals.protein,
                carbs: goals.carbs,
                fat: goals.fat,
                waterGoalMl: goals.waterGoalMl
            ),
            foodEntries: entries,
            exerciseSessions: sessions
        )
    }

    static func foodEntrySummary(_ row: LocalFoodEntry) -> FoodEntrySummary {
        FoodEntrySummary(
            id: row.id,
            foodName: row.foodName,
            mealType: row.mealTypeName,
            quantity: row.quantity,
            unit: row.unit,
            calories: row.calories,
            protein: row.protein,
            carbs: row.carbs,
            fat: row.fat,
            foodId: row.foodId,
            // Must be non-nil or Diary's tap-to-edit silently does nothing:
            // `editableFood` returns nil without it, and the row just doesn't
            // respond. Matches the id `LocalAPIClient.food(_:)` synthesises for
            // the same food's variant.
            variantId: "\(row.foodId)-variant",
            mealTypeId: row.mealTypeId,
            brandName: row.brandName,
            servingSize: row.servingSize,
            servingUnit: row.servingUnit
        )
    }

    static func exercise(_ row: LocalExercise) -> Exercise {
        Exercise(
            id: row.id, name: row.name, category: row.category,
            modality: row.modality.flatMap(ExerciseModality.init(rawValue:)),
            caloriesPerHour: row.caloriesPerHour, source: "manual", isCustom: true
        )
    }

    static func exerciseSets(_ row: LocalExerciseEntry) -> [ExerciseSet]? {
        guard let json = row.setsJSON, let data = json.data(using: .utf8),
              let inputs = try? JSONDecoder().decode([ExerciseSetInput].self, from: data) else { return nil }
        return inputs.enumerated().map { index, input in
            ExerciseSet(
                id: index, setNumber: input.setNumber, setType: input.setType,
                reps: input.reps, weight: input.weight, duration: nil, restTime: nil,
                notes: input.notes, rpe: input.rpe, isPr: false, distance: nil
            )
        }
    }

    static func exerciseSummary(_ row: LocalExerciseEntry) -> ExerciseSessionSummary {
        ExerciseSessionSummary(
            id: row.id,
            name: row.name,
            caloriesBurned: row.caloriesBurned,
            durationMinutes: row.durationMinutes,
            exerciseId: row.exerciseId,
            entryDate: LocalDay.key(row.entryDate), entryTime: row.entryTime, notes: row.notes,
            distance: row.distance, avgHeartRate: row.avgHeartRate, sets: exerciseSets(row),
            modality: row.modality.flatMap(ExerciseModality.init(rawValue:)), exerciseSnapshot: nil
        )
    }
}
