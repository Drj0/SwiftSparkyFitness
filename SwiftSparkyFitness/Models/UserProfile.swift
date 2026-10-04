//
//  UserProfile.swift
//  SwiftSparkyFitness
//
//  Who the calorie estimate is for: onboarding's answers that have no home
//  among the preferences, goals or check-ins.
//
//  On the server these live in two places, verified live:
//  `GET/PUT /api/identity/profiles` holds `gender` and `date_of_birth` (the
//  PUT merges, so a missing key is left alone), and `target_weight` comes
//  back on that same GET but is only written by `POST /api/onboarding`, which
//  wants the whole questionnaire at once — see `OnboardingSubmission`.
//
//  On this device they're four optional columns on `LocalPreferences`, so
//  they ride the same iCloud sync, export and server push the units do.
//

import Foundation

struct UserProfile: Equatable, Sendable {
    /// The two the BMR formulas take. The server lowercases what it stores.
    enum Sex: String, CaseIterable, Sendable {
        case female, male

        var label: String { rawValue.capitalized }
    }

    /// The server's own onboarding values.
    enum PrimaryGoal: String, CaseIterable, Sendable {
        case lose = "lose_weight"
        case maintain = "maintain_weight"
        case gain = "gain_weight"

        var label: String {
            switch self {
            case .lose: return "Lose weight"
            case .maintain: return "Maintain weight"
            case .gain: return "Gain weight"
            }
        }
    }

    var sex: Sex?
    /// "yyyy-MM-dd", the same day-key every other date in the store uses.
    var birthDate: String?
    var primaryGoal: PrimaryGoal?
    /// In the weight-unit preference, like every stored weight.
    var targetWeight: Double?

    var isEmpty: Bool { self == UserProfile() }
}

extension UserProfile: Decodable {
    private enum CodingKeys: String, CodingKey {
        case gender, dateOfBirth = "date_of_birth", targetWeight = "target_weight"
    }

    /// `GET /api/identity/profiles`, which answers `{}` for a user with no
    /// profile row yet. The primary goal isn't on it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sex = (try? container.decodeIfPresent(String.self, forKey: .gender))
            .flatMap { Sex(rawValue: $0.lowercased()) }
        birthDate = try? container.decodeIfPresent(String.self, forKey: .dateOfBirth)
        targetWeight = try? container.decodeIfPresent(Double.self, forKey: .targetWeight)
    }
}

/// `POST /api/onboarding`: every one of these is required (a 400 otherwise),
/// and the keys are camelCase, unlike the rest of the API. It's what marks
/// onboarding done on the server, so the web app stops asking too.
struct OnboardingSubmission: Encodable, Equatable {
    let sex: String
    let primaryGoal: String
    let currentWeight: Double
    let height: Double
    let birthDate: String
    let activityLevel: String
    let targetWeight: Double

    /// Nil until every answer is in.
    init?(profile: UserProfile, currentWeight: Double?, height: Double?, activityLevel: String?) {
        guard let sex = profile.sex, let goal = profile.primaryGoal, let birthDate = profile.birthDate,
              let currentWeight, currentWeight > 0, let height, height > 0,
              let activityLevel, !activityLevel.isEmpty else { return nil }
        self.sex = sex.rawValue
        self.primaryGoal = goal.rawValue
        self.currentWeight = currentWeight
        self.height = height
        self.birthDate = birthDate
        self.activityLevel = activityLevel
        // Maintaining has no target of its own; the server still wants one.
        self.targetWeight = profile.targetWeight ?? currentWeight
    }
}

/// `GET /api/onboarding/status`.
struct OnboardingStatus: Decodable, Equatable {
    let onboardingComplete: Bool
    let onboardingSkipped: Bool
}
