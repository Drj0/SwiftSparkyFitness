//
//  SessionUser.swift
//  SwiftSparkyFitness
//

import Foundation

struct SessionUser: Decodable {
    let email: String
    let name: String?
    /// Used by Diary to bound date navigation (can't browse before the
    /// account existed). Server sends ISO-8601 with fractional seconds,
    /// which the app's shared decoder isn't configured for elsewhere, so
    /// this is parsed locally instead of widening the shared strategy.
    let createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case email, name, createdAt
    }

    init(email: String, name: String?, createdAt: Date? = nil) {
        self.email = email
        self.name = name
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = try container.decode(String.self, forKey: .email)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        if let raw = try container.decodeIfPresent(String.self, forKey: .createdAt) {
            createdAt = SessionUser.isoWithFractionalSeconds.date(from: raw) ?? SessionUser.isoPlain.date(from: raw)
        } else {
            createdAt = nil
        }
    }

    private static let isoWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()
}
