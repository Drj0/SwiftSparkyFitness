//
//  MultiDeviceTests.swift
//  SwiftSparkyFitnessTests
//
//  Step 6 of docs/SYNC_SWITCHING_PLAN.md: more than one device on the same
//  diary, and a change of Apple ID.
//

import XCTest
import SwiftData
@testable import SwiftSparkyFitness

@MainActor
final class MultiDeviceTests: XCTestCase {

    private let account = SyncAccount.key(serverURL: "http://sparky.local:3010", email: "me@example.com")

    // MARK: - Duplicate rows

    /// Two devices each seeded Breakfast; one was then edited. The older copy
    /// goes; the list shows Breakfast once.
    func testAnOlderCopyOfARowIsRemovedAndTheNewerKept() async throws {
        let local = LocalAPIClient(store: LocalStore(inMemory: true))
        let seeded = try XCTUnwrap(local.store.all(LocalMealType.self).first { $0.id == "breakfast" })
        let copy = LocalMealType(id: "breakfast", name: "Breakfast", sortOrder: 10, isVisible: false, isSystemDefault: true)
        local.store.insert(copy) // stamped now: the newer one
        _ = seeded

        let removed = local.store.removeDuplicateRows()

        XCTAssertEqual(removed, 1)
        let breakfasts = local.store.all(LocalMealType.self).filter { $0.id == "breakfast" }
        XCTAssertEqual(breakfasts.map(\.isVisible), [false], "the newer copy survives")
    }

    /// Copies tied on their stamp are left — two devices can't agree on which
    /// to delete — but shown once.
    func testExactlyTiedCopiesAreKeptButShownOnce() async throws {
        let local = LocalAPIClient(store: LocalStore(inMemory: true))
        local.store.preservingStamps {
            local.store.context.insert(LocalMealType(id: "lunch", name: "Lunch", sortOrder: 20, isSystemDefault: true))
            local.store.save()
        }

        XCTAssertEqual(local.store.removeDuplicateRows(), 0)

        let meals = try await local.mealTypes()
        XCTAssertEqual(meals.filter { $0.id == "lunch" }.count, 1)
    }

    /// Removing a duplicate isn't a delete of the row, so it mustn't send one
    /// to the server.
    func testRemovingADuplicateWritesNoTombstone() {
        let store = LocalStore(inMemory: true)
        let older = LocalCheckIn(id: "a", dayKey: "2026-09-10")
        store.insert(older)
        store.setLink(older, serverId: "srv-a", account: account)
        let newer = LocalCheckIn(id: "b", dayKey: "2026-09-10")
        newer.weight = 70
        store.insert(newer)

        store.removeDuplicateRows()

        XCTAssertEqual(store.all(LocalCheckIn.self).map(\.id), ["b"])
        XCTAssertTrue(store.all(LocalTombstone.self).isEmpty)
    }

    // MARK: - A move made on another device

    func testAMoveMadeOnAnotherDeviceIsOfferedOnce() {
        let store = LocalStore(inMemory: true)
        store.insert(LocalHandoff(fromMode: "local", toMode: "server", serverAccount: account, deviceId: "other-iphone"))

        let offered = DiaryHome.moveMadeElsewhere(store: store, currentMode: .local)
        XCTAssertEqual(offered?.toMode, "server")
        XCTAssertEqual(offered.map(DiaryHome.host(of:)), "sparky.local")

        DiaryHome.decline(try! XCTUnwrap(offered))
        XCTAssertNil(DiaryHome.moveMadeElsewhere(store: store, currentMode: .local))
    }

    func testThisDevicesOwnMoveIsNotOffered() {
        let store = LocalStore(inMemory: true)
        store.recordHandoff(from: .local, to: .server, serverAccount: account)
        XCTAssertNil(DiaryHome.moveMadeElsewhere(store: store, currentMode: .local))
    }

    func testAMoveToWhereThisDeviceAlreadyIsIsNotOffered() {
        let store = LocalStore(inMemory: true)
        store.insert(LocalHandoff(fromMode: "local", toMode: "server", serverAccount: account, deviceId: "other-iphone"))
        XCTAssertNil(DiaryHome.moveMadeElsewhere(store: store, currentMode: .server))
    }

    /// An iPad still offline on iCloud when the phone moved the diary to a
    /// server logs two drinks; they reach the phone through iCloud and are
    /// the ones to send — not what was already sent before the move.
    func testEntriesLoggedAfterAMoveAreCounted() async throws {
        let local = LocalAPIClient(store: LocalStore(inMemory: true))
        let day = LocalDay.date("2026-09-10")!
        _ = try await local.logWaterAmount(date: day, milliliters: 250)
        let before = try XCTUnwrap(local.store.all(LocalWaterEntry.self).first)
        local.store.setLink(before, serverId: "srv-1", account: account)
        let move = LocalHandoff(fromMode: "local", toMode: "server", serverAccount: account, date: Date(), deviceId: "phone")
        local.store.insert(move)
        try await Task.sleep(for: .milliseconds(20))
        _ = try await local.logWaterAmount(date: day, milliliters: 250)
        _ = try await local.logWaterAmount(date: day, milliliters: 250)

        XCTAssertEqual(DiaryHome.lateEntries(for: account, store: local.store), 2)
        XCTAssertEqual(DiaryHome.lateEntries(for: "someone-else", store: local.store), 0)
    }

    // MARK: - Apple ID changes

    func testADifferentICloudUserIsNoticedButTheFirstIsnt() {
        UserDefaults.standard.removeObject(forKey: "iCloudUserRecordName")
        ICloudIdentity.changedAt = nil
        defer {
            UserDefaults.standard.removeObject(forKey: "iCloudUserRecordName")
            ICloudIdentity.changedAt = nil
        }

        ICloudIdentity.record(recordName: "_alice")
        XCTAssertNil(ICloudIdentity.changedAt)
        ICloudIdentity.record(recordName: "_alice")
        XCTAssertNil(ICloudIdentity.changedAt)
        ICloudIdentity.record(recordName: "_bob")
        XCTAssertNotNil(ICloudIdentity.changedAt)
    }

    private func withBackupDirectory(_ body: () async throws -> Void) async rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("autobackup-\(UUID().uuidString)")
        AutoBackup.directoryOverride = dir
        ICloudIdentity.changedAt = nil
        defer {
            AutoBackup.directoryOverride = nil
            ICloudIdentity.changedAt = nil
            try? FileManager.default.removeItem(at: dir)
        }
        try await body()
    }

    func testTheAutomaticBackupIsDailyAndRestoresTheDiary() async throws {
        try await withBackupDirectory {
            let source = LocalAPIClient(store: LocalStore(inMemory: true))
            let now = Date()
            AutoBackup.saveIfDue(from: LocalStore(inMemory: true), now: now, account: "alice")
            XCTAssertNil(AutoBackup.latest(), "an empty diary is never backed up")

            _ = try await source.logWaterAmount(date: LocalDay.date("2026-09-10")!, milliliters: 400)
            AutoBackup.saveIfDue(from: source.store, now: now, account: "alice")
            let saved = try XCTUnwrap(AutoBackup.latest())
            XCTAssertEqual(saved.account, "alice")
            AutoBackup.saveIfDue(from: source.store, now: now.addingTimeInterval(3600), account: "alice")
            XCTAssertEqual(AutoBackup.latest()?.url, saved.url, "one a day")

            let fresh = LocalStore(inMemory: true)
            let result = try AutoBackup.restore(saved, into: fresh)
            XCTAssertGreaterThan(result.added, 0)
            XCTAssertEqual(fresh.all(LocalWaterEntry.self).map(\.waterMl), [400])
        }
    }

    /// After an Apple ID change the offered backup is the old account's, and
    /// no new backup (of the new account's diary) is taken meanwhile — so
    /// daily pruning can't push the old one out.
    func testAfterAnAccountChangeTheOldAccountsBackupIsOfferedAndKept() async throws {
        try await withBackupDirectory {
            let diary = LocalAPIClient(store: LocalStore(inMemory: true))
            _ = try await diary.logWaterAmount(date: LocalDay.date("2026-09-10")!, milliliters: 300)
            let day: TimeInterval = 24 * 3600
            let start = Date(timeIntervalSinceNow: -5 * day)
            AutoBackup.saveIfDue(from: diary.store, now: start, account: "alice")

            ICloudIdentity.changedAt = Date()
            for offset in 1...4 {
                AutoBackup.saveIfDue(from: diary.store, now: start.addingTimeInterval(Double(offset) * day), account: "bob")
            }

            XCTAssertEqual(AutoBackup.beforeAccountChange(current: "bob")?.account, "alice")
            XCTAssertEqual(AutoBackup.latest()?.account, "alice", "nothing new while the change is unresolved")
        }
    }

    /// Two devices each started the same day's check-in with different
    /// fields: merged, not one dropped.
    func testTwoCheckInsForOneDayAreMergedNotDropped() {
        let store = LocalStore(inMemory: true)
        let older = LocalCheckIn(id: "phone", dayKey: "2026-09-10")
        older.weight = 72
        store.insert(older)
        store.setLink(older, serverId: "srv-day", account: account)
        let newer = LocalCheckIn(id: "ipad", dayKey: "2026-09-10")
        newer.bodyFatPercentage = 18
        store.insert(newer)

        store.removeDuplicateRows()

        let rows = store.all(LocalCheckIn.self)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.weight, 72)
        XCTAssertEqual(rows.first?.bodyFatPercentage, 18)
        XCTAssertEqual(store.link(kind: LocalCheckIn.syncKind, localKey: "ipad", account: account)?.serverId, "srv-day",
                       "the server link moves to the survivor")
        XCTAssertTrue(store.all(LocalTombstone.self).isEmpty)
    }

    /// A move off a server this device doesn't use isn't offered here.
    func testAMoveOffAnotherServerIsNotOffered() {
        let store = LocalStore(inMemory: true)
        store.insert(LocalHandoff(fromMode: "server", toMode: "local", serverAccount: "http://other:3010|me@example.com", deviceId: "other-iphone"))
        XCTAssertNil(DiaryHome.moveMadeElsewhere(store: store, currentMode: .server, serverAccount: account))
        XCTAssertNotNil(DiaryHome.moveMadeElsewhere(store: store, currentMode: .server, serverAccount: "http://other:3010|me@example.com"))
    }
}
