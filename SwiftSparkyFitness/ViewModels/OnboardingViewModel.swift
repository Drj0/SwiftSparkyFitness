//
//  OnboardingViewModel.swift
//  SwiftSparkyFitness
//
//  First-run setup: who you are, how active, what you're aiming for, and the
//  daily targets that follow (see CalorieTarget). Also reachable from
//  Settings → Goals to recalculate, prefilled with what's already saved.
//
//  Everything it writes goes through the paths the rest of the app already
//  uses, so it syncs and exports like any other edit: units and activity
//  level are preferences, weight and height are today's check-in, the
//  answers are the profile, and the targets go through GoalsViewModel —
//  the one write that must start from a loaded goal row (see NutritionGoals).
//

import Foundation
import Combine

/// Whether onboarding should open on its own.
enum OnboardingGate {
    static let localKey = "onboardingHandled.local"

    /// Per diary: this iPhone's, or one server account's.
    private static func key(account: String?) -> String {
        AppMode.isLocal ? localKey : "onboardingHandled.server.\(account ?? "")"
    }

    static func markHandled(account: String?) {
        UserDefaults.standard.set(true, forKey: key(account: account))
    }

    @MainActor
    static func shouldShow(account: String?) async -> Bool {
        guard !UserDefaults.standard.bool(forKey: key(account: account)) else { return false }
        let start = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        if AppMode.isLocal {
            // Goals alone would catch someone logging for months on the
            // defaults, who isn't new either.
            let client = AppServices.client
            guard (try? await client.goals(date: Date()))?.isSet == false,
                  let logged = try? await client.foodEntries(from: start, to: Date()) else { return false }
            return logged.isEmpty
        }
        // A new server account answers goals with the server's defaults (it
        // seeds an undated row at sign-up), so goals can't say "never set".
        // The server's onboarding flag is the one the web app reads too, but
        // accounts that predate it, or only ever used this app, never set
        // it — so it also takes a diary with nothing in it lately. Asked of
        // the server, not this device's copy, which may not have pulled yet.
        // Unreachable: ask next time.
        let server = APIClient.shared
        guard let status = try? await server.onboardingStatus(),
              !status.onboardingComplete, !status.onboardingSkipped else { return false }
        guard let logged = try? await server.foodEntries(from: start, to: Date()) else { return false }
        return logged.isEmpty
    }

    /// "Skip" means don't ask again — here, and on the server's web app.
    static func skip(account: String?) {
        markHandled(account: account)
        if !AppMode.isLocal { Task { try? await APIClient.shared.skipOnboarding() } }
    }
}

@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case about, body, activity, goal, plan, health
    }

    struct Activity: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
    }

    static let activities = [
        Activity(id: "sedentary", title: "Mostly sitting", detail: "Desk job, little exercise", symbol: "chair.lounge"),
        Activity(id: "lightly_active", title: "Lightly active", detail: "Light exercise 1–3 days a week", symbol: "figure.walk"),
        Activity(id: "moderately_active", title: "Moderately active", detail: "Exercise 3–5 days a week", symbol: "figure.run"),
        Activity(id: "very_active", title: "Very active", detail: "Hard exercise 6–7 days a week", symbol: "figure.strengthtraining.traditional"),
        Activity(id: "extra_active", title: "Extra active", detail: "Physical job or training twice a day", symbol: "figure.climbing"),
    ]

    /// The Goals screen's quick splits, protein/carbs/fat in percent.
    enum MacroSplit: String, CaseIterable, Identifiable {
        case balanced = "Balanced", lowCarb = "Low carb", highProtein = "High protein"

        var id: String { rawValue }
        var ratio: (protein: Double, carbs: Double, fat: Double) {
            switch self {
            case .balanced: return (30, 40, 30)
            case .lowCarb: return (35, 25, 40)
            case .highProtein: return (40, 30, 30)
            }
        }
    }

    @Published var step: Step = .about
    /// Which way the last move went, so Back slides the other way.
    @Published private(set) var isGoingBack = false
    /// Steps passed with Skip. Their answers are left out of the save and
    /// the plan fills in for them (see `assumptions`).
    @Published private(set) var skippedSteps: Set<Step> = []
    @Published var sex: UserProfile.Sex?
    /// Starts 30 years back so the wheel lands somewhere useful, but that
    /// isn't an answer until it's moved (or loaded): see `hasBirthDate`.
    @Published var birthDate = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date() {
        didSet { hasBirthDate = true }
    }
    private(set) var hasBirthDate = false
    /// Switching unit converts what's typed: 82 kg must not become 82 lb.
    @Published var weightUnit = "kg" {
        didSet {
            guard weightUnit != oldValue else { return }
            weightText = Self.converted(weightText) { CalorieTarget.kilograms($0, unit: oldValue) / CalorieTarget.kilograms(1, unit: self.weightUnit) }
            targetWeightText = Self.converted(targetWeightText) { CalorieTarget.kilograms($0, unit: oldValue) / CalorieTarget.kilograms(1, unit: self.weightUnit) }
            snapPace()
        }
    }
    @Published var heightUnit = "cm" {
        didSet {
            guard heightUnit != oldValue else { return }
            heightText = Self.converted(heightText) { CalorieTarget.centimetres($0, unit: oldValue) / CalorieTarget.centimetres(1, unit: self.heightUnit) }
        }
    }
    // Pasted text or a hardware keyboard gets past the number pad, so each
    // keeps digits and one decimal separator, seven characters at most.
    @Published var weightText = "" { didSet { if let clean = Self.sanitized(weightText) { weightText = clean } } }
    @Published var heightText = "" { didSet { if let clean = Self.sanitized(heightText) { heightText = clean } } }
    @Published var activityLevel: String?
    @Published var goal: UserProfile.PrimaryGoal? { didSet { snapPace() } }
    @Published var targetWeightText = "" { didSet { if let clean = Self.sanitized(targetWeightText) { targetWeightText = clean } } }
    /// kg per week.
    @Published var pace = 0.5
    @Published var calories: Double = 0
    @Published var waterMl: Double = 0
    @Published var macroSplit: MacroSplit = .balanced
    @Published private(set) var isSaving = false
    @Published var bannerMessage: String?

    let goals: GoalsViewModel
    let offersHealth: Bool
    private let apiClient: APIClientProtocol
    private let account: String?
    private var cancellable: AnyCancellable?

    init(account: String?, apiClient: APIClientProtocol = AppServices.client,
         offersHealth: Bool = HealthKitService.shared.isAvailable && !HealthSync.isEnabled) {
        self.account = account
        self.apiClient = apiClient
        self.offersHealth = offersHealth
        goals = GoalsViewModel(date: Date(), apiClient: apiClient)
        // The goal row's load state drives this screen's Save.
        cancellable = goals.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    var steps: [Step] { offersHealth ? Step.allCases : Step.allCases.filter { $0 != .health } }
    var progress: Double { Double((steps.firstIndex(of: step) ?? 0) + 1) / Double(steps.count) }

    // MARK: - Prefill

    /// What's already known, so a rerun from Settings starts from it and a
    /// server account brings the answers given on the web.
    func load() async {
        await goals.load()
        if let prefs = try? await apiClient.userPreferences() {
            if prefs.defaultWeightUnit == "lbs" { weightUnit = "lbs" }
            if prefs.defaultMeasurementUnit == "inches" { heightUnit = "inches" }
            let profile = (try? await apiClient.profile()) ?? UserProfile()
            // The stored level defaults to "sedentary" for everyone, so it
            // only counts as an answer once onboarding has been through.
            if !profile.isEmpty, let level = prefs.activityLevel, CalorieTarget.activityMultipliers[level] != nil {
                activityLevel = activityLevel ?? level
            }
            // Only what's still unanswered: a tap made while this loaded wins.
            sex = sex ?? profile.sex
            goal = goal ?? profile.primaryGoal
            if !hasBirthDate, let date = profile.birthDate.flatMap(LocalDay.date) { birthDate = date }
            if targetWeightText.isEmpty, let target = profile.targetWeight { targetWeightText = Self.text(target) }
        }
        let yearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        if let rows = try? await apiClient.bodyMeasurements(from: yearAgo, to: Date()) {
            let latest = rows.sorted { $0.entryDate > $1.entryDate }.map(\.measurements)
            if weightText.isEmpty, let weight = latest.compactMap(\.weight).first { weightText = Self.text(weight) }
            if heightText.isEmpty, let height = latest.compactMap(\.height).first { heightText = Self.text(height) }
        }
    }

    private static func text(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// The cleaned text, or nil when it's already clean. Nil matters: the
    /// caller assigns only on a change, and assigning unconditionally (an
    /// `inout` write-back does) re-entered `didSet` until the stack ran out.
    static func sanitized(_ text: String) -> String? {
        var seenSeparator = false
        let cleaned = String(text.filter { character in
            if character.isASCII, character.isNumber { return true }
            if (character == "." || character == ","), !seenSeparator { seenSeparator = true; return true }
            return false
        }.prefix(7))
        return cleaned == text ? nil : cleaned
    }

    private static func converted(_ text: String, _ convert: (Double) -> Double) -> String {
        guard let value = number(text) else { return text }
        return Self.text((convert(value) * 10).rounded() / 10)
    }

    // MARK: - Answers

    private static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    var weight: Double? { Self.number(weightText) }
    var height: Double? { Self.number(heightText) }
    var targetWeight: Double? { Self.number(targetWeightText) }
    var age: Int { CalorieTarget.age(birthDate: birthDate) }

    var weightRange: ClosedRange<Double> { weightUnit == "lbs" ? 66...660 : 30...300 }
    var heightRange: ClosedRange<Double> { heightUnit == "inches" ? 39...98 : 100...250 }
    var birthDateRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let now = Date()
        return (calendar.date(byAdding: .year, value: -100, to: now) ?? now)...(calendar.date(byAdding: .year, value: -13, to: now) ?? now)
    }

    var weightError: String? {
        guard let weight else { return nil }
        return weightRange.contains(weight) ? nil : "Between \(Int(weightRange.lowerBound)) and \(Int(weightRange.upperBound)) \(weightUnitLabel)"
    }
    var heightError: String? {
        guard let height else { return nil }
        return heightRange.contains(height) ? nil : "Between \(Int(heightRange.lowerBound)) and \(Int(heightRange.upperBound)) \(heightUnitLabel)"
    }
    /// Losing needs a lower target, gaining a higher one.
    var targetError: String? {
        guard let target = targetWeight, let weight, let goal else { return nil }
        guard weightRange.contains(target) else { return "That doesn't look right" }
        switch goal {
        case .lose where target >= weight: return "Lower than your weight now (\(Self.text(weight)) \(weightUnitLabel))"
        case .gain where target <= weight: return "Higher than your weight now (\(Self.text(weight)) \(weightUnitLabel))"
        default: return nil
        }
    }

    var weightUnitLabel: String { weightUnit == "lbs" ? "lb" : "kg" }
    var heightUnitLabel: String { heightUnit == "inches" ? "in" : "cm" }

    var canContinue: Bool {
        switch step {
        case .about: return sex != nil
        case .body: return weight != nil && height != nil && weightError == nil && heightError == nil
        case .activity: return activityLevel != nil
        case .goal:
            guard let goal else { return false }
            return goal == .maintain || (targetWeight != nil && targetError == nil)
        case .plan: return goals.loaded != nil && calories > 0
        case .health: return true
        }
    }

    // MARK: - Pace and plan

    /// Gentle to brisk, in the unit the person weighs in.
    var paceOptions: [(kg: Double, label: String)] {
        let steps: [Double] = goal == .gain ? [0.25, 0.5] : [0.25, 0.5, 0.75, 1]
        if weightUnit == "lbs" {
            return steps.map { ($0 * 2 * 0.45359237, "\(($0 * 2).formatted()) lb") }
        }
        return steps.map { ($0, "\($0.formatted()) kg") }
    }

    /// Keeps the pace on one of the offered choices: a unit or goal change
    /// moves them, and 0.5 kg isn't any of the lb ones.
    private func snapPace() {
        guard let closest = paceOptions.min(by: { abs($0.kg - pace) < abs($1.kg - pace) }) else { return }
        pace = closest.kg
    }

    // What the plan may use: an answer only counts if its step wasn't
    // skipped and it's valid.
    private var usableWeight: Double? { skippedSteps.contains(.body) || weightError != nil ? nil : weight }
    private var usableHeight: Double? { skippedSteps.contains(.body) || heightError != nil ? nil : height }
    private var usableSex: UserProfile.Sex? { skippedSteps.contains(.about) ? nil : sex }
    private var usableBirthDate: String? { skippedSteps.contains(.about) || !hasBirthDate ? nil : LocalDay.key(birthDate) }
    private var usableActivity: String? { skippedSteps.contains(.activity) ? nil : activityLevel }
    var usableGoal: UserProfile.PrimaryGoal { skippedSteps.contains(.goal) ? .maintain : (goal ?? .maintain) }
    private var usableTarget: Double? {
        guard !skippedSteps.contains(.goal), usableGoal != .maintain, targetError == nil else { return nil }
        return targetWeight
    }

    var weightKg: Double? { usableWeight.map { CalorieTarget.kilograms($0, unit: weightUnit) } }

    /// Nil without height and weight: there's nothing to estimate from.
    /// The rest falls back — age 30, the midpoint of the two sex offsets,
    /// mostly sitting — so a skipped question costs accuracy, not the plan.
    var maintenance: Double? {
        guard let weightKg, let height = usableHeight else { return nil }
        let heightCm = CalorieTarget.centimetres(height, unit: heightUnit)
        let ageYears = usableBirthDate == nil ? 30 : age
        let multiplier = CalorieTarget.activityMultipliers[usableActivity ?? "sedentary"] ?? 1.2
        let bmr: Double
        if let sex = usableSex {
            bmr = CalorieTarget.bmr(weightKg: weightKg, heightCm: heightCm, age: ageYears, sex: sex)
        } else {
            bmr = (CalorieTarget.bmr(weightKg: weightKg, heightCm: heightCm, age: ageYears, sex: .male)
                + CalorieTarget.bmr(weightKg: weightKg, heightCm: heightCm, age: ageYears, sex: .female)) / 2
        }
        return bmr * multiplier
    }

    var suggestedCalories: Double {
        guard let maintenance else { return GoalsViewModel.suggestedCalories }
        return CalorieTarget.daily(maintenance: maintenance, goal: usableGoal, kgPerWeek: pace)
    }

    /// What the plan had to guess, and the step that would fix it.
    var assumptions: [(text: String, step: Step)] {
        var list: [(String, Step)] = []
        if maintenance == nil {
            list.append(("Add your height and weight for a target that fits you", .body))
        } else {
            if usableSex == nil || usableBirthDate == nil { list.append(("Add your sex and birthday for a closer estimate", .about)) }
            if usableActivity == nil { list.append(("Assumed mostly sitting — add your activity level", .activity)) }
        }
        if skippedSteps.contains(.goal) || goal == nil { list.append(("Set a goal to lose or gain weight", .goal)) }
        return list
    }

    /// Opened from the plan's list: answering it goes straight back there.
    private var returnsToPlan = false

    func revisit(_ target: Step) {
        returnsToPlan = true
        skippedSteps.remove(target)
        isGoingBack = true
        step = target
    }

    /// The pace's deficit hit the floor, so the target is slower than asked.
    var isAtFloor: Bool { usableGoal == .lose && maintenance != nil && suggestedCalories <= CalorieTarget.floor }

    /// When the target weight is reached at this pace, or nil when maintaining.
    var estimatedArrival: Date? {
        guard let target = usableTarget, let weightKg, pace > 0 else { return nil }
        let kgToGo = abs(weightKg - CalorieTarget.kilograms(target, unit: weightUnit))
        return Calendar.current.date(byAdding: .day, value: Int((kgToGo / pace * 7).rounded()), to: Date())
    }

    var split: (protein: Double, carbs: Double, fat: Double) { macroSplit.ratio }

    /// The daily change the pace asks for, signed: negative is a deficit.
    var paceAdjustment: Double {
        guard let maintenance else { return 0 }
        return suggestedCalories - (maintenance / 10).rounded() * 10
    }

    /// "8 kg to lose", once a target is typed.
    var targetSummary: String? {
        guard let goal, goal != .maintain, let target = targetWeight, let weight, targetError == nil else { return nil }
        let difference = abs(weight - target)
        guard difference > 0 else { return nil }
        return "\(Self.text((difference * 10).rounded() / 10)) \(weightUnitLabel) to \(goal == .lose ? "lose" : "gain")"
    }

    func grams(_ share: Double, perGram: Double) -> Int {
        Int(((calories * share / 100 / perGram) / 5).rounded(.down) * 5)
    }

    func adjustCalories(by amount: Double) {
        calories = min(max(calories + amount, CalorieTarget.floor), GoalsViewModel.Field.calories.maximum)
    }

    // MARK: - Navigation

    func next() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        let upcoming = returnsToPlan ? .plan : steps[index + 1]
        returnsToPlan = false
        if upcoming == .plan {
            calories = suggestedCalories
            waterMl = weightKg.map(CalorieTarget.waterMl) ?? 2500
            // Protein-forward when cutting, so less muscle goes with the fat.
            macroSplit = usableGoal == .lose ? .highProtein : .balanced
        }
        isGoingBack = false
        step = upcoming
    }

    func back() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        returnsToPlan = false
        isGoingBack = true
        step = steps[index - 1]
    }

    /// Passes this question by; the plan works around the gap.
    func skipStep() {
        skippedSteps.insert(step)
        next()
    }

    /// Continue, which also un-skips a step answered on a second visit.
    func answerStep() {
        skippedSteps.remove(step)
        next()
    }

    /// Leaves setup without saving, and doesn't ask again.
    func skipAll() { OnboardingGate.skip(account: account) }

    // MARK: - Save

    /// Writes everything; false leaves the plan step up with the reason.
    func save() async -> Bool {
        guard goals.loaded != nil else { return false }
        isSaving = true
        bannerMessage = nil
        defer { isSaving = false }
        // Only what was answered: a skipped question leaves whatever was
        // stored before untouched.
        do {
            if !skippedSteps.contains(.body) {
                _ = try await apiClient.updateUserPreference(.weight, to: weightUnit)
                _ = try await apiClient.updateUserPreference(.measurement, to: heightUnit)
            }
            if let activity = usableActivity {
                _ = try await apiClient.updateUserPreference(.activityLevel, to: activity)
            }
            var body: [BodyField: Double?] = [:]
            if let usableWeight { body[.weight] = usableWeight }
            if let usableHeight { body[.height] = usableHeight }
            if !body.isEmpty {
                _ = try await apiClient.upsertBodyMeasurements(BodyMeasurementsInput(date: Date(), values: body))
            }
            var profile = (try? await apiClient.profile()) ?? UserProfile()
            if let usableSex { profile.sex = usableSex }
            if let usableBirthDate { profile.birthDate = usableBirthDate }
            if !skippedSteps.contains(.goal), let goal {
                profile.primaryGoal = goal
                profile.targetWeight = goal == .maintain ? usableWeight : usableTarget
            }
            if !profile.isEmpty { try await apiClient.saveProfile(profile) }
        } catch {
            bannerMessage = error.localizedDescription
            Haptics.error()
            return false
        }
        goals.setValue(calories, for: .calories)
        goals.applySplit(protein: split.protein, carbs: split.carbs, fat: split.fat)
        goals.setValue(waterMl, for: .water)
        guard await goals.save() else {
            bannerMessage = goals.bannerMessage ?? "Couldn't save your goals."
            return false
        }
        OnboardingGate.markHandled(account: account)
        return true
    }
}
