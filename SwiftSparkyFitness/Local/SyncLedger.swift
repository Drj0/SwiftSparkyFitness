//
//  SyncLedger.swift
//  SwiftSparkyFitness
//
//  The bookkeeping that lets a diary move between the device store and a
//  server, in either direction and any number of times, without copying a
//  row twice or resurrecting one that was deleted. See
//  docs/SYNC_SWITCHING_PLAN.md.
//
//  Three record types, all synced through CloudKit with the diary itself so
//  every device agrees on them:
//
//  - `LocalSyncLink` pairs a local row with the server row it was copied
//    to or from, per server account. A linked row is updated on the next
//    switch, never created again.
//  - `LocalTombstone` remembers that a *linked* row was deleted here, so the
//    next switch can delete its server copy instead of leaving it behind.
//    Unlinked rows need no tombstone: the server never had them.
//  - `LocalHandoff` records each switch of the diary's home. The latest one
//    bounds "what changed since we last moved", and its `toMode` is the
//    home every device should be using.
//
//  Same CloudKit rules as LocalModels: no `.unique`, no relationships, every
//  property defaulted.
//

import Foundation
import SwiftData

/// A local row that can be linked to a server row, and whose edits and
/// deletes the switching flows need to see. `LocalStore.save()` stamps
/// `updatedAt` and writes tombstones for every conforming model, so no write
/// site has to remember to.
protocol SyncTracked: PersistentModel {
    /// Stable per type, and never renamed: links and tombstones store it.
    static var syncKind: String { get }
    /// What identifies the row across devices. The row's own id, except
    /// goals, which are keyed by the day they take effect.
    var syncKey: String { get }
    /// `.distantPast` on rows written before tracking existed, which is the
    /// honest "unknown": they are unlinked, so a switch copies them anyway.
    var updatedAt: Date { get set }
}

extension LocalFood: SyncTracked {
    static var syncKind: String { "food" }
    var syncKey: String { id }
}

extension LocalFoodEntry: SyncTracked {
    static var syncKind: String { "foodEntry" }
    var syncKey: String { id }
}

extension LocalExercise: SyncTracked {
    static var syncKind: String { "exercise" }
    var syncKey: String { id }
}

extension LocalExerciseEntry: SyncTracked {
    static var syncKind: String { "exerciseEntry" }
    var syncKey: String { id }
}

extension LocalWaterEntry: SyncTracked {
    static var syncKind: String { "waterEntry" }
    var syncKey: String { id }
}

extension LocalCheckIn: SyncTracked {
    static var syncKind: String { "checkIn" }
    var syncKey: String { id }
}

extension LocalGoalRow: SyncTracked {
    static var syncKind: String { "goal" }
    var syncKey: String { dayKey }
}

extension LocalPreferences: SyncTracked {
    static var syncKind: String { "preferences" }
    var syncKey: String { id }
}

extension LocalMealType: SyncTracked {
    static var syncKind: String { "mealType" }
    var syncKey: String { id }
}

/// One local row paired with one server row, for one server account.
@Model
final class LocalSyncLink {
    var kind: String = ""
    var localKey: String = ""
    var serverId: String = ""
    /// `SyncAccount.key` — a different server or account has no links, so it
    /// is treated as a fresh destination rather than matched by accident.
    var serverAccount: String = ""
    /// When the two sides last agreed. A row stamped later than this has been
    /// edited here since, and is what the next push sends.
    var linkedAt: Date = Date()
    /// Foods only: the server food's default variant, which every food entry
    /// logged against it must name alongside the food id.
    var serverVariantId: String?

    init(kind: String, localKey: String, serverId: String, serverAccount: String, linkedAt: Date = Date(), serverVariantId: String? = nil) {
        self.kind = kind
        self.localKey = localKey
        self.serverId = serverId
        self.serverAccount = serverAccount
        self.linkedAt = linkedAt
        self.serverVariantId = serverVariantId
    }
}

/// A linked row deleted on this side, waiting for the next switch to delete
/// its server copy. Removed once that has happened.
@Model
final class LocalTombstone {
    var kind: String = ""
    var localKey: String = ""
    var deletedAt: Date = Date()

    init(kind: String, localKey: String, deletedAt: Date = Date()) {
        self.kind = kind
        self.localKey = localKey
        self.deletedAt = deletedAt
    }
}

/// One move of the diary's home.
@Model
final class LocalHandoff {
    var id: String = UUID().uuidString
    var date: Date = Date()
    /// `AppMode` raw values.
    var fromMode: String = ""
    var toMode: String = ""
    /// The server account on the server side of the move, when known.
    var serverAccount: String?
    /// Set when the move had to leave data behind — a dead server's copy was
    /// only current up to this moment, so anything newer is still there.
    var gapUntil: Date?
    /// The install that made the move, so other devices can tell a move made
    /// elsewhere (offer to follow it) from their own.
    var deviceId: String?

    init(fromMode: String, toMode: String, serverAccount: String? = nil, gapUntil: Date? = nil, date: Date = Date(), deviceId: String? = DeviceIdentity.id) {
        self.fromMode = fromMode
        self.toMode = toMode
        self.serverAccount = serverAccount
        self.gapUntil = gapUntil
        self.date = date
        self.deviceId = deviceId
    }
}

/// This install, as far as the handoff log is concerned. Not
/// `identifierForVendor`, which can change under an app that's still
/// installed; a UUID of its own is stable for the life of the install.
enum DeviceIdentity {
    private static let defaultsKey = "syncDeviceId"

    static var id: String {
        if let existing = UserDefaults.standard.string(forKey: defaultsKey) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: defaultsKey)
        return fresh
    }
}

/// Identifies a server account for links. The session carries no user id,
/// so the account is the normalised server address plus the sign-in email;
/// both are stable for an account and differ between accounts.
enum SyncAccount {
    static func key(serverURL: String, email: String) -> String {
        var address = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while address.hasSuffix("/") { address.removeLast() }
        let user = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(address)|\(user)"
    }
}

// MARK: - Store access

extension LocalStore {
    func link<T: SyncTracked>(for row: T, account: String) -> LocalSyncLink? {
        link(kind: T.syncKind, localKey: row.syncKey, account: account)
    }

    /// Newest first: two devices linking one row before either has seen the
    /// other's link leaves two (CloudKit can't enforce uniqueness), and the
    /// latest is the one that reflects the server as it now is.
    func link(kind: String, localKey: String, account: String) -> LocalSyncLink? {
        fetch(LocalSyncLink.self, where: #Predicate {
            $0.kind == kind && $0.localKey == localKey && $0.serverAccount == account
        }, sortBy: [SortDescriptor(\.linkedAt, order: .reverse)]).first
    }

    /// Links a row, replacing any earlier link for the same row and account —
    /// a row has exactly one server copy per account.
    /// `version` is the `updatedAt` of the copy the server now holds. The
    /// sync engine passes the stamp it read *before* sending, so an edit made
    /// while the request was in flight is newer than the link and goes out on
    /// the next push instead of being marked as synced. Omitted, the link is
    /// as fresh as the row.
    @discardableResult
    func setLink<T: SyncTracked>(_ row: T, serverId: String, account: String, serverVariantId: String? = nil, version: Date? = nil) -> LocalSyncLink {
        setLink(kind: T.syncKind, localKey: row.syncKey, serverId: serverId, account: account,
                serverVariantId: serverVariantId, version: version ?? max(Date(), row.updatedAt))
    }

    /// `save: false` leaves the change pending for the caller's own save —
    /// the pull, which must land a whole range in one.
    @discardableResult
    func setLink(kind: String, localKey: String, serverId: String, account: String, serverVariantId: String? = nil, version: Date, save shouldSave: Bool = true) -> LocalSyncLink {
        if let existing = link(kind: kind, localKey: localKey, account: account) {
            existing.serverId = serverId
            existing.linkedAt = version
            if let serverVariantId { existing.serverVariantId = serverVariantId }
            if shouldSave { save() }
            return existing
        }
        let created = LocalSyncLink(kind: kind, localKey: localKey, serverId: serverId,
                                    serverAccount: account, linkedAt: version, serverVariantId: serverVariantId)
        context.insert(created)
        if shouldSave { save() }
        return created
    }

    /// Edited here since it last matched the server, or never sent at all.
    func needsPush<T: SyncTracked>(_ row: T, account: String) -> Bool {
        guard let link = link(for: row, account: account) else { return true }
        return row.updatedAt > link.linkedAt
    }

    func links(kind: String, account: String) -> [LocalSyncLink] {
        fetch(LocalSyncLink.self, where: #Predicate { $0.kind == kind && $0.serverAccount == account })
    }

    /// Each row's newest link stamp for one kind, in one fetch. For a scan
    /// over a whole table, where `needsPush` per row is a fetch per row —
    /// thousands of them on a year's diary, on every write. The newest stamp
    /// is what `link(kind:localKey:account:)` returns, so the answers match.
    func linkStamps(kind: String, account: String) -> [String: Date] {
        links(kind: kind, account: account).reduce(into: [:]) { stamps, link in
            stamps[link.localKey] = max(stamps[link.localKey] ?? .distantPast, link.linkedAt)
        }
    }

    func tombstones(kind: String) -> [LocalTombstone] {
        fetch(LocalTombstone.self, where: #Predicate { $0.kind == kind }, sortBy: [SortDescriptor(\.deletedAt)])
    }

    @discardableResult
    func recordHandoff(from: AppMode, to: AppMode, serverAccount: String?, gapUntil: Date? = nil) -> LocalHandoff {
        if self === LocalStore.shared { DiaryHome.usesICloudDiary = true }
        let handoff = LocalHandoff(fromMode: from.rawValue, toMode: to.rawValue, serverAccount: serverAccount, gapUntil: gapUntil)
        insert(handoff)
        return handoff
    }

    /// Newest by date. Two devices switching at once both write one; the
    /// later wins, which is what the plan specifies.
    var latestHandoff: LocalHandoff? {
        var descriptor = FetchDescriptor<LocalHandoff>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Where the diary lives according to the synced log, which can differ
    /// from this device's own `AppMode` when another device moved it.
    var syncedHome: AppMode? {
        latestHandoff.flatMap { AppMode(rawValue: $0.toMode) }
    }
}
