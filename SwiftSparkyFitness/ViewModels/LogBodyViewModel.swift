//
//  LogBodyViewModel.swift
//  SwiftSparkyFitness
//
//  Drives both body sheets — Log Weight and Body Measurements. They're one
//  view model because they're one backend write: weight and the measurement
//  columns live on the same `check_in_measurements` row, upserted by
//  (user, date). Only the fields a sheet actually shows are sent, so saving
//  a weight can't blank out this morning's waist measurement.
//
//  An emptied field that previously held a value is sent as an explicit
//  null, which clears that column — the same per-field clear the reference
//  web client does, and the reason "delete my weight" doesn't have to mean
//  deleting the whole day's row.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class LogBodyViewModel: ObservableObject {
    /// Identifiable so Diary can drive a `.sheet(item:)` with it, the same
    /// way it presents the food/exercise edit sheets.
    enum Kind: Equatable, Identifiable {
        case weight, measurements

        var id: String {
            switch self {
            case .weight: return "weight"
            case .measurements: return "measurements"
            }
        }

        var fields: [BodyField] {
            switch self {
            case .weight: return BodyField.weightSheetFields
            case .measurements: return BodyField.measurementSheetFields
            }
        }

        var title: String {
            switch self {
            case .weight: return "Log Weight"
            case .measurements: return "Measurements"
            }
        }
    }

    let kind: Kind
    let preferences: UserPreferences
    let minDate: Date
    let maxDate: Date

    @Published var date: Date
    @Published var text: [String: String] = [:]
    @Published private(set) var fieldErrors: [String: String] = [:]
    @Published private(set) var isSaving = false
    @Published var bannerMessage: String?

    /// What's already stored for `date`, so an untouched field can be left
    /// alone and a cleared one can be told apart from one that was never
    /// filled in.
    @Published private(set) var existing: BodyMeasurements

    private let apiClient: APIClientProtocol

    var fields: [BodyField] { kind.fields }

    init(
        kind: Kind,
        date: Date,
        existing: BodyMeasurements = .none,
        preferences: UserPreferences = .serverDefaults,
        minDate: Date,
        maxDate: Date,
        apiClient: APIClientProtocol = APIClient.shared
    ) {
        self.kind = kind
        self.date = date
        self.existing = existing
        self.preferences = preferences
        self.minDate = minDate
        self.maxDate = maxDate
        self.apiClient = apiClient
        self.text = Self.prefill(existing, fields: kind.fields, preferences: preferences)
    }

    private static func prefill(_ existing: BodyMeasurements, fields: [BodyField], preferences: UserPreferences) -> [String: String] {
        var result: [String: String] = [:]
        for field in fields {
            if let value = existing.value(for: field) {
                // Trailing ".0" reads like a typo in an input field, so a
                // whole number is shown as one.
                result[field.rawValue] = value == value.rounded() ? String(Int(value)) : String(value)
            }
        }
        return result
    }

    func binding(for field: BodyField) -> Binding<String> {
        Binding(
            get: { self.text[field.rawValue] ?? "" },
            set: { self.text[field.rawValue] = $0 }
        )
    }

    func error(for field: BodyField) -> String? { fieldErrors[field.rawValue] }

    func unitLabel(for field: BodyField) -> String { field.unitLabel(preferences) }

    /// Reloads what's stored when the sheet's date changes — the same sheet
    /// pointed at a different day must prefill that day's values, not carry
    /// the previous day's numbers into an upsert.
    func reloadExisting() async {
        do {
            let loaded = try await apiClient.bodyMeasurements(date: date)
            existing = loaded
            text = Self.prefill(loaded, fields: fields, preferences: preferences)
            fieldErrors = [:]
        } catch {
            // A failed reload leaves the form as-is rather than wiping what
            // the user has typed; the save itself will surface any real
            // problem.
            bannerMessage = error.localizedDescription
        }
    }

    /// The write this form would make: a parsed number per filled field, and
    /// an explicit nil (→ JSON null → cleared column) for a field that was
    /// emptied but holds a stored value. Fields that are empty and unset are
    /// left out entirely.
    private func pendingValues() -> [BodyField: Double?] {
        var values: [BodyField: Double?] = [:]
        for field in fields {
            let raw = (text[field.rawValue] ?? "").trimmingCharacters(in: .whitespaces)
            if raw.isEmpty {
                if existing.value(for: field) != nil { values[field] = .some(nil) }
            } else if let parsed = Double(raw.replacingOccurrences(of: ",", with: ".")) {
                values[field] = .some(parsed)
            }
        }
        return values
    }

    @discardableResult
    private func validate() -> Bool {
        var errors: [String: String] = [:]
        for field in fields {
            let raw = (text[field.rawValue] ?? "").trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            guard let parsed = Double(raw.replacingOccurrences(of: ",", with: ".")) else {
                errors[field.rawValue] = "Numbers only"
                continue
            }
            if parsed <= 0 {
                errors[field.rawValue] = "Must be more than 0"
            } else if parsed < field.minimum {
                // Only BMR has a real lower bound (600). Without this the
                // server answers a raw 400 for an otherwise sensible number.
                errors[field.rawValue] = "Must be at least \(Int(field.minimum))"
            } else if parsed > field.maximum {
                errors[field.rawValue] = "That looks too high"
            }
        }

        // The weight sheet exists to record a weight, so an empty one is a
        // validation failure rather than a silent no-op. Clearing a logged
        // weight is a delete (swipe in Diary), not an empty save.
        if kind == .weight, (text[BodyField.weight.rawValue] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            errors[BodyField.weight.rawValue] = "How much do you weigh?"
        }

        fieldErrors = errors
        return errors.isEmpty
    }

    /// Whether this form has anything to write. The Save button stays
    /// enabled regardless — an empty weight sheet should answer with the
    /// field-level "How much do you weigh?" rather than a dead button —
    /// but save() uses this to avoid sending an empty request.
    var hasPendingWrite: Bool {
        !pendingValues().isEmpty
    }

    @discardableResult
    func save() async -> Bool {
        guard validate() else {
            Haptics.error()
            return false
        }
        let values = pendingValues()
        guard !values.isEmpty else {
            // Measurements sheet opened and closed without touching
            // anything — nothing to write, and nothing to complain about.
            return true
        }

        isSaving = true
        bannerMessage = nil
        defer { isSaving = false }
        do {
            existing = try await apiClient.upsertBodyMeasurements(
                BodyMeasurementsInput(date: date, values: values)
            )
            Haptics.success()
            return true
        } catch {
            bannerMessage = error.localizedDescription
            Haptics.error()
            return false
        }
    }
}
