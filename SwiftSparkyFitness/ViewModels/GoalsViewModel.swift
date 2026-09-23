//
//  GoalsViewModel.swift
//  SwiftSparkyFitness
//
//  Drives the Set Goals sheet. Five fields — calories, the three macros and
//  a water target — which is what Today's rings and macro row actually read.
//
//  THE LOAD IS A PRECONDITION FOR THE SAVE, NOT A CONVENIENCE
//  ----------------------------------------------------------
//  `POST /api/goals/manage-timeline` replaces the whole row and zeroes every
//  column it isn't sent (see NutritionGoals). The app only models five of
//  roughly thirty, so the write has to be built by mutating a value that came
//  *from* the server — anything else silently wipes sodium, fibre, the
//  vitamins, exercise targets and the per-meal split that the web client can
//  set.
//
//  So if the load fails there is deliberately nothing to save: `loaded` stays
//  nil, Save stays disabled, and the sheet shows a retry instead. Letting the
//  user "just set a calorie goal" against a failed load is exactly the
//  destructive case.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class GoalsViewModel: ObservableObject {
    enum Field: String, CaseIterable, Identifiable {
        case calories, protein, carbs, fat, water

        var id: String { rawValue }

        var title: String {
            switch self {
            case .calories: return "Daily calories"
            case .protein: return "Protein"
            case .carbs: return "Carbs"
            case .fat: return "Fat"
            case .water: return "Water"
            }
        }

        /// Generous ceilings — these exist to catch a slipped decimal point or
        /// a pasted phone number, not to police anyone's diet.
        var maximum: Double {
            switch self {
            case .calories: return 20000
            case .protein, .carbs, .fat: return 2000
            case .water: return 20000
            }
        }
    }

    let date: Date

    @Published var text: [String: String] = [:]
    @Published private(set) var fieldErrors: [String: String] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published var bannerMessage: String?
    @Published private(set) var loadFailed = false

    /// The server's own row. Nil until a successful load — and while it's nil
    /// there is nothing safe to write.
    @Published private(set) var loaded: NutritionGoals?

    private let apiClient: APIClientProtocol

    // No `preferences` here on purpose: every unit on this form is fixed by
    // the column it writes. Calories are kcal, macros are grams, and the
    // water target is `water_goal_ml` — millilitres whatever the display
    // preference says, since converting would store the wrong number.
    init(date: Date, apiClient: APIClientProtocol = APIClient.shared) {
        self.date = date
        self.apiClient = apiClient
    }

    var canSave: Bool { loaded != nil && !isSaving }

    func unitLabel(for field: Field) -> String {
        switch field {
        case .calories: return "kcal"
        case .protein, .carbs, .fat: return "g"
        // The column is `water_goal_ml`, so this figure is millilitres
        // regardless of the display preference. Converting here would write
        // the wrong number into the column.
        case .water: return "ml"
        }
    }

    func binding(for field: Field) -> Binding<String> {
        Binding(
            get: { self.text[field.rawValue] ?? "" },
            set: { self.text[field.rawValue] = $0 }
        )
    }

    func error(for field: Field) -> String? { fieldErrors[field.rawValue] }

    func load() async {
        isLoading = true
        loadFailed = false
        bannerMessage = nil
        defer { isLoading = false }
        do {
            let goals = try await apiClient.goals(date: date)
            loaded = goals
            text = [
                Field.calories.rawValue: Self.display(goals.calories),
                Field.protein.rawValue: Self.display(goals.protein),
                Field.carbs.rawValue: Self.display(goals.carbs),
                Field.fat.rawValue: Self.display(goals.fat),
                Field.water.rawValue: Self.display(goals.waterGoalMl),
            ]
        } catch {
            loadFailed = true
            bannerMessage = error.localizedDescription
            Haptics.error()
        }
    }

    /// A zero means "not set" for every one of these, and showing "0" in the
    /// field invites the user to save it back as a real goal of zero.
    private static func display(_ value: Double?) -> String {
        guard let value, value > 0 else { return "" }
        return value == value.rounded() ? String(Int(value)) : String(value)
    }

    private func parsed(_ field: Field) -> Double? {
        let raw = (text[field.rawValue] ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: "."))
    }

    @discardableResult
    private func validate() -> Bool {
        var errors: [String: String] = [:]
        for field in Field.allCases {
            let raw = (text[field.rawValue] ?? "").trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            guard let value = Double(raw.replacingOccurrences(of: ",", with: ".")) else {
                errors[field.rawValue] = "Numbers only"
                continue
            }
            if value <= 0 {
                errors[field.rawValue] = "Must be more than 0"
            } else if value > field.maximum {
                errors[field.rawValue] = "That looks too high"
            }
        }

        // This sheet exists to set a calorie goal — it's reached from a card
        // that says the goal isn't set. Saving it blank would leave the user
        // exactly where they started, with no explanation.
        if (text[Field.calories.rawValue] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            errors[Field.calories.rawValue] = "Set a daily calorie goal"
        }

        fieldErrors = errors
        return errors.isEmpty
    }

    @discardableResult
    func save() async -> Bool {
        guard var goals = loaded else {
            // Unreachable from the UI (Save is disabled), but writing without
            // a loaded row is the destructive case, so it fails closed.
            bannerMessage = "Couldn't read your current goals, so they weren't changed."
            Haptics.error()
            return false
        }
        guard validate() else {
            Haptics.error()
            return false
        }

        goals.calories = parsed(.calories)
        goals.protein = parsed(.protein)
        goals.carbs = parsed(.carbs)
        goals.fat = parsed(.fat)
        goals.waterGoalMl = parsed(.water)

        isSaving = true
        bannerMessage = nil
        defer { isSaving = false }
        do {
            try await apiClient.saveGoals(goals, startingOn: date)
            loaded = goals
            Haptics.success()
            return true
        } catch {
            bannerMessage = error.localizedDescription
            Haptics.error()
            return false
        }
    }
}
