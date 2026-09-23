//
//  MealType.swift
//  SwiftSparkyFitness
//
//  A meal category. Four ship with the server (breakfast/lunch/snacks/dinner)
//  and the user can add their own.
//
//  WHAT THE SERVER ALLOWS, VERIFIED LIVE
//  -------------------------------------
//  The four defaults are rows with `user_id: null`, and they are protected:
//
//    * renaming or reordering one  -> 403 "Cannot rename or reorder system
//      default meal types."
//    * deleting one                -> 403 "Cannot delete system default meal
//      types."
//    * hiding one, or giving it a default time -> 200, allowed.
//
//  A user-created category allows all four. Deleting one that still has food
//  logged against it is refused with 409 "Cannot delete this meal type
//  because it is still in use." — the server protects the entries, so the app
//  doesn't have to reason about orphans.
//
//  Despite `user_id` reading back as null on a default, **edits are per-user**:
//  hiding breakfast on one account left a second account's breakfast visible
//  (checked with a freshly created user). The server keeps the override
//  itself, so nothing here has to model ownership of the hidden state.
//

import Foundation

struct MealType: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let sortOrder: Int
    /// Null for the server's own defaults, set for a user-created category.
    let userId: String?
    let isVisible: Bool?
    let showInQuickLog: Bool?
    /// `"16:30:00"`, or nil. Kept as the server's string rather than parsed:
    /// nothing in the app schedules anything by it yet, and round-tripping the
    /// exact value avoids inventing a timezone the column doesn't carry.
    let defaultTime: String?

    init(
        id: String,
        name: String,
        sortOrder: Int,
        userId: String? = nil,
        isVisible: Bool? = nil,
        showInQuickLog: Bool? = nil,
        defaultTime: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.userId = userId
        self.isVisible = isVisible
        self.showInQuickLog = showInQuickLog
        self.defaultTime = defaultTime
    }

    /// One of the server's four. Can be hidden or given a time, but not
    /// renamed, reordered or deleted — the server answers 403.
    var isSystemDefault: Bool { userId == nil }

    /// Older rows predate the column, so a missing value means visible.
    var visible: Bool { isVisible ?? true }

    /// "Pre-Workout" is stored as typed, but the four defaults are stored
    /// lowercase, so they need capitalising for display.
    var displayName: String {
        isSystemDefault ? name.capitalized : name
    }
}

extension Array where Element == MealType {
    /// The categories a logging screen should offer. The endpoint returns
    /// hidden ones too — it has to, so the management screen can show them —
    /// so every consumer that isn't that screen has to filter.
    var visibleOnly: [MealType] {
        filter(\.visible).sorted { $0.sortOrder < $1.sortOrder }
    }
}

/// Fields a write may carry. Only what's being changed is sent: the update is
/// a partial merge, and sending `name` for a system default is a 403 even if
/// the value is unchanged.
struct MealTypeInput: Encodable {
    var name: String?
    var sortOrder: Int?
    var isVisible: Bool?
    var defaultTime: String??

    // Left in camelCase so the shared encoder's convertToSnakeCase does the
    // translation, the same as every other request body in the app.
    private enum CodingKeys: String, CodingKey {
        case name, sortOrder, isVisible, defaultTime
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(sortOrder, forKey: .sortOrder)
        try container.encodeIfPresent(isVisible, forKey: .isVisible)
        // Double optional: `nil` means "don't touch it", `.some(nil)` means
        // "clear the time", which has to reach the server as an explicit null.
        if let defaultTime {
            try container.encode(defaultTime, forKey: .defaultTime)
        }
    }
}
