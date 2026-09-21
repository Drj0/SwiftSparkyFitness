//
//  WaterLog.swift
//  SwiftSparkyFitness
//
//  Water is a two-table story on this backend, and the app reads both:
//
//  * `water_intake_entries` — the itemised ledger. One row per drink, with
//    an id, so a single mis-tap can be deleted. GET .../{date}/log.
//  * `water_intake` — the per-(date, source) aggregate the daily summary
//    reads. Never written directly: the server recomputes it as SUM(ledger)
//    after every ledger change, which is why the aggregate-overwriting
//    `PUT /water-intake/{id}` is not used anywhere here — the next quick-add
//    would wipe it. Confirmed by reading recomputeWaterAggregateForUser and
//    verified live.
//
//  Every shape below came from live calls, not the OpenAPI doc (Module 3
//  couldn't find a per-entry water API at all; it's on the /api/v2 prefix).
//

import Foundation

enum Water {
    /// The backend's own amount for one drink when the user has no water
    /// container configured: `2000 / 8` in measurementService.
    /// upsertWaterIntake. Verified live — a bare `change_drinks: 1` logs
    /// exactly 250 ml. Not a number this app picked.
    static let defaultMlPerDrink: Double = 250

    /// Matches the `change_drinks` bound the server's zod schema enforces
    /// (it loops once per drink, so it refuses an unbounded count).
    static let maxDrinksPerRequest = 100
}

/// Response of both GET .../water-intake/{date} and the quick-add POST.
/// `waterMl` is the number to show; `manualMl` is the hand-logged subset,
/// which is all a "−" control can ever remove (provider-synced water is
/// owned by its provider).
struct WaterTotals: Decodable, Equatable, Sendable {
    let waterMl: Double
    let manualMl: Double
    let ledgerMl: Double
    let foodMl: Double

    static let zero = WaterTotals(waterMl: 0, manualMl: 0, ledgerMl: 0, foodMl: 0)
}

/// One drink in the ledger. `containerName` is snapshotted at log time, so
/// it survives the container being renamed or deleted — which is what makes
/// the custom-amount flow in APIClient.logWaterAmount safe.
struct WaterLogEntry: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let waterMl: Double
    let containerName: String?
    let source: String?
    let loggedAt: Date?

    /// Only hand-logged water can be removed by this app — a row synced from
    /// a provider belongs to that provider, and the server's "−" control
    /// only ever touches `source = 'manual'` rows.
    var isManual: Bool { (source ?? "manual") == "manual" }

    private enum CodingKeys: String, CodingKey {
        case id, waterMl, containerName, source, loggedAt
    }

    init(id: String, waterMl: Double, containerName: String? = nil, source: String? = "manual", loggedAt: Date? = nil) {
        self.id = id
        self.waterMl = waterMl
        self.containerName = containerName
        self.source = source
        self.loggedAt = loggedAt
    }

    /// `logged_at` is ISO-8601 with fractional seconds, which the app's
    /// shared decoder isn't configured for — parsed locally, the same way
    /// SessionUser.createdAt already is, rather than widening the shared
    /// strategy and risking every other model's decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        waterMl = try container.decode(Double.self, forKey: .waterMl)
        containerName = try container.decodeIfPresent(String.self, forKey: .containerName)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        if let raw = try container.decodeIfPresent(String.self, forKey: .loggedAt) {
            loggedAt = WaterLogEntry.isoWithFractionalSeconds.date(from: raw) ?? WaterLogEntry.isoPlain.date(from: raw)
        } else {
            loggedAt = nil
        }
    }

    private static let isoWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()
}
