//
//  MultiDevice.swift
//  SwiftSparkyFitness
//
//  What having the diary on more than one device needs beyond the sync
//  itself. See docs/SYNC_SWITCHING_PLAN.md, step 6.
//
//  - Duplicate rows: every new device seeds the four meal categories and a
//    preferences row before iCloud has delivered the other device's, and
//    CloudKit can't enforce uniqueness, so the same row can exist twice.
//  - A move made elsewhere: when one device moves the diary to a server (or
//    back), the others learn it from the synced handoff log and offer to
//    follow — and anything they logged after the move is offered to be sent,
//    not lost.
//  - A change of Apple ID, after which iOS can replace this device's copy of
//    the iCloud diary with the new account's: a daily automatic backup kept
//    on this device, outside iCloud, is offered back.
//

import CloudKit
import CryptoKit
import Foundation
import OSLog
import SwiftData

// MARK: - Duplicate rows

extension LocalStore {
    /// Removes copies of a row that are strictly older than its newest copy.
    ///
    /// Only strictly older ones. Two devices clean up independently and then
    /// sync their deletes; for copies tied on their stamp there is nothing
    /// both devices would agree on, and each deleting "the other one" would
    /// delete both. Exact ties are left, and hidden where they'd show twice
    /// (`LocalAPIClient.mealTypes`); the first edit to either breaks the tie,
    /// and the next clean-up removes the other.
    @discardableResult
    func removeDuplicateRows() -> Int {
        var removed = 0
        func dedupe<Row: SyncTracked>(_ rows: [Row], by key: (Row) -> String) {
            for group in Dictionary(grouping: rows, by: key).values where group.count > 1 {
                guard let newest = group.map(\.updatedAt).max() else { continue }
                for row in group where row.updatedAt < newest {
                    context.delete(row)
                    removed += 1
                }
            }
        }
        applyingRemoteChanges {
            dedupe(all(LocalMealType.self), by: \.id)
            dedupe(all(LocalPreferences.self), by: \.id)
            dedupe(all(LocalFood.self), by: \.id)
            dedupe(all(LocalFoodEntry.self), by: \.id)
            dedupe(all(LocalExercise.self), by: \.id)
            dedupe(all(LocalExerciseEntry.self), by: \.id)
            dedupe(all(LocalWaterEntry.self), by: \.id)
            mergeCheckIns(&removed)
            // One goal row per day: a row is the whole goal, so the newer wins.
            dedupe(all(LocalGoalRow.self), by: \.dayKey)

            let links = Dictionary(grouping: all(LocalSyncLink.self)) { "\($0.kind)|\($0.localKey)|\($0.serverAccount)" }
            for group in links.values where group.count > 1 {
                guard let newest = group.map(\.linkedAt).max() else { continue }
                for link in group where link.linkedAt < newest {
                    context.delete(link)
                    removed += 1
                }
            }
            // A failed save must not leave the deletes pending: the next
            // ordinary save would tombstone them, and the push would delete
            // rows on the server that still have a live survivor here.
            if removed > 0, !save() { context.rollback(); removed = 0 }
        }
        return removed
    }

    /// One check-in per day, but two devices can each start that day's row
    /// with different fields — weight on one, body fat on the other. The
    /// rows are merged, not one dropped: the newest keeps its values and
    /// takes any the others have that it doesn't, and inherits their server
    /// links. Every device makes the same merge.
    private func mergeCheckIns(_ removed: inout Int) {
        let fields: [WritableKeyPath<LocalCheckIn, Double?>] = [
            \.weight, \.neck, \.waist, \.hips, \.height, \.bodyFatPercentage,
            \.muscleMassKg, \.boneMassKg, \.bodyWaterPercentage, \.bmr
        ]
        for group in Dictionary(grouping: all(LocalCheckIn.self), by: \.dayKey).values where group.count > 1 {
            let ordered = group.sorted { $0.updatedAt > $1.updatedAt }
            guard var survivor = ordered.first, ordered[1].updatedAt < survivor.updatedAt else { continue }
            for older in ordered.dropFirst() where older.updatedAt < survivor.updatedAt {
                for field in fields where survivor[keyPath: field] == nil {
                    survivor[keyPath: field] = older[keyPath: field]
                }
                let olderKey = older.id
                for link in fetch(LocalSyncLink.self, where: #Predicate { $0.kind == "checkIn" && $0.localKey == olderKey }) {
                    if self.link(kind: LocalCheckIn.syncKind, localKey: survivor.id, account: link.serverAccount) == nil {
                        link.localKey = survivor.id
                    } else {
                        context.delete(link)
                    }
                }
                context.delete(older)
                removed += 1
            }
        }
    }
}

/// Runs the clean-up once iCloud has gone quiet, then has the open screens
/// re-read what arrived — rather than after each of
/// the dozens of import events a first sync produces — each would re-read
/// every row on the main actor. Local mode only: in server mode the iCloud
/// diary isn't the one in use.
@MainActor
enum DuplicateSweep {
    private static var pending: Task<Void, Never>?

    static func schedule(after delay: Duration = .seconds(5)) {
        guard AppMode.isLocal else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, AppMode.isLocal else { return }
            LocalStore.shared.removeDuplicateRows()
            // Always, not only when copies were removed: this runs after
            // iCloud has delivered rows, and nothing else tells open screens
            // to re-read. After a reinstall, Today sat empty over a diary
            // that had already come back.
            NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
        }
    }
}

// MARK: - A move made on another device

/// The latest move of the diary's home, when another device made it and
/// this one hasn't followed or declined it.
@MainActor
enum DiaryHome {
    private static let declinedKey = "declinedHandoffIds"

    /// `serverAccount` is the account this device uses in server mode: a
    /// move off a *different* server or login isn't this device's to follow.
    static func moveMadeElsewhere(store: LocalStore = .shared, currentMode: AppMode? = AppMode.current,
                                  serverAccount: String? = nil) -> LocalHandoff? {
        guard let latest = store.latestHandoff,
              let madeBy = latest.deviceId, madeBy != DeviceIdentity.id,
              let current = currentMode, latest.toMode != current.rawValue,
              !declined.contains(latest.id) else { return nil }
        if latest.toMode == AppMode.local.rawValue, latest.serverAccount != serverAccount { return nil }
        return latest
    }

    /// Whether this device has ever kept a diary in iCloud. Until it has,
    /// server mode leaves the iCloud store closed: opening it would seed and
    /// start mirroring a diary nobody uses.
    static var usesICloudDiary: Bool {
        get { UserDefaults.standard.bool(forKey: "usesICloudDiary") }
        set { UserDefaults.standard.set(newValue, forKey: "usesICloudDiary") }
    }

    static func decline(_ handoff: LocalHandoff) {
        UserDefaults.standard.set(Array(declined.union([handoff.id])), forKey: declinedKey)
    }

    private static var declined: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: declinedKey) ?? [])
    }

    /// The server address a handoff's account names (`SyncAccount.key` is
    /// "address|email").
    static func serverURL(of handoff: LocalHandoff) -> String? {
        handoff.serverAccount?.split(separator: "|", maxSplits: 1).first.map(String.init)
    }

    static func host(of handoff: LocalHandoff) -> String {
        serverURL(of: handoff).flatMap { URL(string: $0)?.host } ?? "your server"
    }

    /// Entries in this device's own diary that aren't on `account`'s server
    /// and were logged after the diary moved there — on a device still
    /// working offline from iCloud when the move was made. They reach this
    /// device through iCloud and only it can send them.
    ///
    /// Anything the push would still send — new rows, rows edited since,
    /// deletes — not rows dated after the move: other devices' clocks aren't
    /// comparable, and a row logged just before the move but synced to this
    /// device after it counts the same.
    static func lateEntries(for account: String, store: LocalStore = .shared) -> Int {
        guard let latest = store.latestHandoff, latest.toMode == AppMode.server.rawValue,
              latest.serverAccount == account, !declined.contains(latest.id) else { return 0 }
        let plan = ServerPush(store: store, server: APIClient.shared, account: account).plan()
        return plan.creates + plan.updates + plan.deletes
    }

    /// Follows another device's move to a server: this device points at the
    /// same server, and anything it logged since that move — which only it
    /// has — is offered to be sent after sign-in.
    static func followToServer(_ handoff: LocalHandoff) {
        if let url = serverURL(of: handoff) {
            UserDefaults.standard.set(url, forKey: ServerConfig.defaultsKey)
        }
        PendingServerHandoff.isPending = handoff.serverAccount.map { lateEntries(for: $0) > 0 } ?? false
        decline(handoff) // answered either way
        AppMode.current = .server
    }
}

// MARK: - Apple ID changes

/// A copy of the iCloud diary kept on this device, outside iCloud, once a
/// day. If the Apple ID changes, iOS can replace the iCloud diary on this
/// device with the new account's; this is what brings the old one back.
///
/// Each backup is tagged with the iCloud account it was taken under, and
/// none is taken or pruned while a change of account is unresolved — so the
/// new account's diary can never push the old one's last copy out.
@MainActor
enum AutoBackup {
    static let keep = 3
    private static let logger = Logger(subsystem: "drj.SwiftSparkyFitness", category: "AutoBackup")

    /// Test seam.
    static var directoryOverride: URL?
    private static var directory: URL {
        directoryOverride ?? URL.applicationSupportDirectory.appending(path: "AutoBackup", directoryHint: .isDirectory)
    }

    struct Backup {
        let url: URL
        let date: Date
        /// A hash of the iCloud user it was taken under ("none" signed out).
        let account: String
    }

    /// Writes today's backup if there isn't one from the last day. Nothing
    /// for an empty diary — an empty backup must never replace a real one —
    /// and nothing while an account change is waiting to be dealt with.
    static func saveIfDue(from store: LocalStore = .shared, now: Date = Date(), account: String? = ICloudIdentity.currentTag) {
        guard ICloudIdentity.changedAt == nil else { return }
        if let latest = latest(), abs(now.timeIntervalSince(latest.date)) < 24 * 3600 { return }
        guard store.hasDiaryEntries() else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try DiaryArchive(from: store).encoded()
            let url = directory.appending(path: "diary-\(Int(now.timeIntervalSince1970))-\(account ?? "none").json")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            for old in backups().dropFirst(keep) { try? FileManager.default.removeItem(at: old.url) }
        } catch {
            logger.error("Automatic backup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func latest() -> Backup? { backups().first }

    /// The backup to offer after an account change: the newest one taken
    /// under a different account than the current one, or else the newest
    /// from before the change was noticed.
    static func beforeAccountChange(current: String? = ICloudIdentity.currentTag, changedAt: Date? = ICloudIdentity.changedAt) -> Backup? {
        let all = backups()
        if let other = all.first(where: { $0.account != (current ?? "none") }) { return other }
        guard let changedAt else { return nil }
        return all.first { $0.date < changedAt }
    }

    /// Newest first.
    private static func backups() -> [Backup] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard parts.count >= 2, parts[0] == "diary", let seconds = TimeInterval(parts[1]) else { return nil }
            return Backup(url: url, date: Date(timeIntervalSince1970: seconds), account: parts.count > 2 ? String(parts[2]) : "none")
        }
        .sorted { $0.date > $1.date }
    }

    /// Merges a backup in — nothing is deleted, the newer copy of each row
    /// wins — exactly like restoring an export.
    static func restore(_ backup: Backup, into store: LocalStore = .shared) throws -> DiaryArchive.RestoreResult {
        try DiaryArchive.decode(Data(contentsOf: backup.url)).restore(into: store)
    }

    /// "Delete all local data" means these too.
    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Notices the iCloud account on this device changing to a different one.
/// `CKAccountChanged` fires for sign-in and sign-out too; only a different
/// user record means a different account. Not main-actor bound: it only
/// touches UserDefaults (thread-safe) and CloudKit.
enum ICloudIdentity {
    private static let recordKey = "iCloudUserRecordName"
    static let changedAtKey = "iCloudAccountChangedAt"

    /// When a switch to a different account was noticed, until the user
    /// restores or dismisses it.
    /// Stored as seconds since the reference date, so Settings can observe it
    /// with `@AppStorage`.
    static var changedAt: Date? {
        get {
            let seconds = UserDefaults.standard.double(forKey: changedAtKey)
            return seconds > 0 ? Date(timeIntervalSinceReferenceDate: seconds) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSinceReferenceDate, forKey: changedAtKey)
            } else {
                UserDefaults.standard.removeObject(forKey: changedAtKey)
            }
        }
    }

    /// The current iCloud user, hashed, for tagging backups.
    static var currentTag: String? {
        UserDefaults.standard.string(forKey: recordKey).map { name in
            SHA256.hash(data: Data(name.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func check(containerIdentifier: String = LocalStore.cloudKitContainerIdentifier) async {
        guard let user = try? await CKContainer(identifier: containerIdentifier).userRecordID() else { return }
        record(recordName: user.recordName)
    }

    /// Split out so the decision can be tested without iCloud.
    static func record(recordName: String) {
        let previous = UserDefaults.standard.string(forKey: recordKey)
        if let previous, previous != recordName { changedAt = Date() }
        UserDefaults.standard.set(recordName, forKey: recordKey)
    }
}
