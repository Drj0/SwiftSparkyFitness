//
//  ExerciseFormatting.swift
//  SwiftSparkyFitness
//
//  One way of describing a session — "3 × 8 · 60 kg", "5 km · 30 min" —
//  shared by the day list, Log Exercise's recents and the editor's "last
//  time" line, so the same workout never reads three ways.
//
//  Units come from the user's preference and are never converted: weights
//  and distances are stored in whatever unit they were logged in (the rule
//  Module 5 set for body measurements). The set editor and day rows used to
//  say "kg" whatever the preference was.
//

import Foundation

enum ExerciseFormatting {
    /// "100" for a whole number, "102.5" otherwise.
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// "45 min", or "1 h 10 min" past an hour.
    static func duration(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        guard total >= 60 else { return "\(total) min" }
        let remainder = total % 60
        return remainder == 0 ? "\(total / 60) h" : "\(total / 60) h \(remainder) min"
    }

    /// Identical sets say the numbers that matter — "3 × 8 · 60 kg" —
    /// rather than a count; mixed ones say the count and the heaviest set.
    static func sets(_ sets: [(reps: Int?, weight: Double?)], weightUnit: String) -> String? {
        let logged = sets.filter { $0.reps != nil || $0.weight != nil }
        guard let first = logged.first else { return nil }
        let weightPart: (Double?) -> String = { weight in
            weight.map { " · \(number($0)) \(weightUnit)" } ?? ""
        }
        if let reps = first.reps, logged.allSatisfy({ $0.reps == first.reps && $0.weight == first.weight }) {
            return "\(logged.count) × \(reps)\(weightPart(first.weight))"
        }
        let count = "\(logged.count) set\(logged.count == 1 ? "" : "s")"
        if let heaviest = logged.compactMap(\.weight).max() {
            return "\(count) · up to \(number(heaviest)) \(weightUnit)"
        }
        return count
    }

    /// The one-line description of a session, branching on how it's logged.
    static func detail(
        modality: ExerciseModality,
        sets setList: [(reps: Int?, weight: Double?)],
        durationMinutes: Double?,
        distance: Double?,
        weightUnit: String,
        distanceUnit: String
    ) -> String {
        let time = durationMinutes.flatMap { $0 > 0 ? duration($0) : nil }
        switch modality {
        case .weightReps, .repsOnly:
            return sets(setList, weightUnit: weightUnit) ?? time ?? ""
        case .durationDistance:
            let far = distance.flatMap { $0 > 0 ? "\(number($0)) \(distanceUnit)" : nil }
            return [far, time].compactMap { $0 }.joined(separator: " · ")
        case .duration:
            return time ?? ""
        }
    }

    static func detail(_ session: ExerciseSessionSummary, weightUnit: String, distanceUnit: String) -> String {
        detail(
            modality: session.effectiveModality,
            sets: session.setsList.map { ($0.reps, $0.weight) },
            durationMinutes: session.durationMinutes,
            distance: session.distance,
            weightUnit: weightUnit,
            distanceUnit: distanceUnit
        )
    }

    static func detail(_ last: ExerciseLastSession, fallbackModality: ExerciseModality?, weightUnit: String, distanceUnit: String) -> String {
        detail(
            modality: last.modality ?? fallbackModality ?? .duration,
            sets: last.sets.map { ($0.reps, $0.weight) },
            durationMinutes: last.durationMinutes,
            distance: last.distance,
            weightUnit: weightUnit,
            distanceUnit: distanceUnit
        )
    }

    /// "Today", "Yesterday", "3 days ago", then the date — how long ago
    /// matters more than which date, until it's a while back.
    static func relativeDay(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case 2..<7: return "\(days) days ago"
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}

extension ExerciseEntryInput {
    /// The same session again, on `date` — what one-tap "log again" sends.
    init(repeating last: ExerciseLastSession, exercise: Exercise, on date: Date) {
        self.init(
            exerciseId: exercise.id,
            modality: last.modality ?? exercise.modality ?? .duration,
            entryDate: date,
            durationMinutes: last.durationMinutes,
            caloriesBurned: last.caloriesBurned
        )
        distance = last.distance
        sets = last.sets.enumerated().map { index, set in
            var copy = set
            copy.setNumber = index + 1
            return copy
        }
    }

    /// A logged session copied to another day — the day list's "Log again".
    init(repeating session: ExerciseSessionSummary, on date: Date) {
        self.init(
            exerciseId: session.exerciseId ?? "",
            modality: session.effectiveModality,
            entryDate: date,
            durationMinutes: session.durationMinutes,
            caloriesBurned: session.caloriesBurned ?? 0
        )
        distance = session.distance
        avgHeartRate = session.avgHeartRate
        sets = session.setsList.enumerated().map { index, set in
            ExerciseSetInput(setNumber: index + 1, setType: set.setType ?? "Working Set", reps: set.reps, weight: set.weight, rpe: set.rpe)
        }
    }
}
