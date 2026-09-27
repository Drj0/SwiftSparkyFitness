//
//  ServerSyncTests.swift
//  SwiftSparkyFitnessTests
//
//  Step 5 of docs/SYNC_SWITCHING_PLAN.md: server mode working from this
//  device's copy. Out of range the diary still reads and writes; back in
//  range everything logged meanwhile reaches the server, and what changed
//  on the server arrives here — without duplicates either way.
//

import XCTest
import SwiftData
@testable import SwiftSparkyFitness

@MainActor
final class ServerSyncTests: XCTestCase {

    private let serverURL = "http://sparky.local:3010"

    /// These tests run inside the app on a real simulator: the signed-in
    /// session they overwrite belongs to whoever uses that simulator.
    private var savedSession: Any?

    override func setUp() async throws {
        savedSession = UserDefaults.standard.object(forKey: "cachedSessionUser")
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedSession, forKey: "cachedSessionUser")
    }
    private let user = SessionUser(email: "me@example.com", name: "Me", createdAt: LocalDay.date("2026-08-01"))
    private let today = Calendar.current.startOfDay(for: Date())

    private func oats(_ client: LocalAPIClient) async throws -> Food {
        try await client.materializeExternalFood(Food(
            id: "oats", name: "Oats", brand: nil,
            defaultVariant: FoodVariant(id: "oats-v", servingSize: 100, servingUnit: "g", calories: 380, protein: 13, carbs: 67, fat: 7)
        ))
    }

    /// A coordinator over one in-memory copy, against a fake server.
    private func makeSync(_ server: FakeSyncServer) -> (ServerSync, LocalAPIClient) {
        let store = LocalStore(inMemory: true)
        let sync = ServerSync(server: server, storeFor: { _ in store })
        sync.activate(user: user, serverURL: serverURL)
        return (sync, LocalAPIClient(store: store))
    }

    // MARK: - Out of range and back

    func testChangesMadeOfflineReachTheServerWhenItsBack() async throws {
        let server = FakeSyncServer()
        let (sync, device) = makeSync(server)
        server.isOffline = true
        let food = try await oats(device)
        try await device.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 100, entryDate: today))
        _ = try await device.logWaterAmount(date: today, milliliters: 300)

        await sync.syncNow()
        XCTAssertEqual(sync.status, .offline)
        XCTAssertGreaterThan(sync.pendingCount, 0)
        let offlineDay = try await device.dailySummary(date: today)
        XCTAssertEqual(offlineDay.foodEntries.count, 1, "the diary works offline")

        server.isOffline = false
        await sync.syncNow()

        XCTAssertEqual(sync.status, .idle)
        XCTAssertEqual(sync.pendingCount, 0)
        let onServer = try await server.backing.dailySummary(date: today)
        XCTAssertEqual(onServer.foodEntries.count, 1)
        XCTAssertEqual(onServer.waterIntake, 300, accuracy: 0.5)
        let afterSync = try await device.dailySummary(date: today)
        XCTAssertEqual(afterSync.foodEntries.count, 1, "nothing came back twice")
    }

    func testAChangeMadeOnTheServerArrivesHere() async throws {
        let server = FakeSyncServer()
        let (sync, device) = makeSync(server)
        await sync.syncNow()
        let food = try await oats(server.backing)
        try await server.backing.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "dinner", quantity: 200, entryDate: today))

        await sync.syncNow()

        let day = try await device.dailySummary(date: today)
        XCTAssertEqual(day.foodEntries.map(\.quantity), [200])
    }

    /// The first sync reads the whole history; later ones only recent days.
    func testTheFirstSyncBringsTheWholeHistory() async throws {
        let server = FakeSyncServer()
        let old = Calendar.current.date(byAdding: .day, value: -40, to: today)!
        let food = try await oats(server.backing)
        try await server.backing.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 50, entryDate: old))
        let store = LocalStore(inMemory: true)
        let sync = ServerSync(server: server, storeFor: { _ in store })
        let account = SyncAccount.key(serverURL: serverURL, email: user.email)
        InitialPull.reset(account: account)
        defer { InitialPull.reset(account: account) }
        sync.activate(user: SessionUser(email: user.email, name: nil, createdAt: Calendar.current.date(byAdding: .day, value: -60, to: today)),
                      serverURL: serverURL)

        await sync.syncNow()

        XCTAssertEqual(store.all(LocalFoodEntry.self).count, 1)
        XCTAssertTrue(InitialPull.isDone(account: account))
    }

    /// Opening an old day re-reads it: a web edit far outside the recent
    /// window still shows up where the user is looking.
    func testOpeningADayRefreshesItFromTheServer() async throws {
        let server = FakeSyncServer()
        let (sync, device) = makeSync(server)
        await sync.syncNow()
        let old = Calendar.current.date(byAdding: .day, value: -30, to: today)!
        let food = try await oats(server.backing)
        try await server.backing.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 75, entryDate: old))

        await sync.refresh(day: old, timeout: .seconds(5))

        let day = try await device.dailySummary(date: old)
        XCTAssertEqual(day.foodEntries.map(\.quantity), [75])
    }

    /// Syncs queue behind each other; two at once can't copy a row twice.
    func testOverlappingSyncsDontDuplicate() async throws {
        let server = FakeSyncServer()
        let (sync, device) = makeSync(server)
        let food = try await oats(device)
        try await device.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 100, entryDate: today))
        let serverFood = try await oats(server.backing)
        try await server.backing.createFoodEntry(FoodEntryInput(food: serverFood, mealTypeId: "dinner", quantity: 200, entryDate: today))

        async let first: Void = sync.syncNow()
        async let second: Void = sync.syncNow()
        async let third: Void = sync.refresh(day: today, timeout: .seconds(5))
        _ = await (first, second, third)

        let mine = try await device.dailySummary(date: today)
        let theirs = try await server.backing.dailySummary(date: today)
        XCTAssertEqual(mine.foodEntries.count, 2)
        XCTAssertEqual(theirs.foodEntries.count, 2)
    }

    // MARK: - Leaving the server

    /// Server → this device, from the copy: works with the server gone, and
    /// carries links and unsent deletes so going back later sends only what
    /// changed.
    func testTheCopyMovesToThisDevicesDiaryWithItsLinks() async throws {
        let server = FakeSyncServer()
        let (sync, cache) = makeSync(server)
        let food = try await oats(cache)
        try await cache.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 100, entryDate: today))
        try await cache.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "dinner", quantity: 40, entryDate: today))
        await sync.syncNow()
        // Offline now: one more entry logged, one deleted, neither sent.
        server.isOffline = true
        try await cache.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "snacks", quantity: 20, entryDate: today))
        let dinner = try XCTUnwrap(cache.store.all(LocalFoodEntry.self).first { $0.quantity == 40 })
        try await cache.deleteFoodEntry(id: dinner.id)
        let account = try XCTUnwrap(sync.account)

        let iCloud = LocalAPIClient(store: LocalStore(inMemory: true))
        try StoreTransfer.copy(from: cache.store, to: iCloud.store, account: account)

        let day = try await iCloud.dailySummary(date: today)
        XCTAssertEqual(Set(day.foodEntries.map(\.quantity)), [100, 20])
        // Back to the server later: only the unsent entry and the delete go.
        server.isOffline = false
        let plan = ServerPush(store: iCloud.store, server: server, account: account).plan()
        XCTAssertEqual(plan.creates, 1)
        XCTAssertEqual(plan.deletes, 1)
        _ = try await ServerPush(store: iCloud.store, server: server, account: account).run()
        let onServer = try await server.backing.dailySummary(date: today)
        XCTAssertEqual(Set(onServer.foodEntries.map(\.quantity)), [100, 20])
    }

    /// iCloud → server → server mode → back to iCloud: the diary the iCloud
    /// store sent comes back from the copy under the server's ids, and must
    /// match its originals instead of doubling them.
    func testARoundTripThroughServerModeDoesNotDoubleTheDiary() async throws {
        let server = FakeSyncServer()
        let iCloud = LocalAPIClient(store: LocalStore(inMemory: true))
        let food = try await oats(iCloud)
        try await iCloud.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 100, entryDate: today))
        _ = try await iCloud.logWaterAmount(date: today, milliliters: 300)
        let account = SyncAccount.key(serverURL: serverURL, email: user.email)
        _ = try await ServerPush(store: iCloud.store, server: server, account: account).run()

        let (sync, _) = makeSync(server)
        await sync.syncNow()
        try StoreTransfer.copy(from: sync.store, to: iCloud.store, account: account)

        XCTAssertEqual(iCloud.store.all(LocalFoodEntry.self).count, 1)
        XCTAssertEqual(iCloud.store.all(LocalWaterEntry.self).count, 1)
        XCTAssertEqual(iCloud.store.all(LocalFood.self).count, 1)
        XCTAssertTrue(ServerPush(store: iCloud.store, server: server, account: account).plan().isEmpty)
    }

    /// A delete in the copy doesn't override an edit this diary made after it.
    func testATransferredDeleteLosesToALaterEditHere() async throws {
        let server = FakeSyncServer()
        let (sync, cache) = makeSync(server)
        let food = try await oats(cache)
        try await cache.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 100, entryDate: today))
        await sync.syncNow()
        let account = try XCTUnwrap(sync.account)
        let iCloud = LocalAPIClient(store: LocalStore(inMemory: true))
        try StoreTransfer.copy(from: cache.store, to: iCloud.store, account: account)
        let entryId = try XCTUnwrap(cache.store.all(LocalFoodEntry.self).first?.id)
        try await cache.deleteFoodEntry(id: entryId)
        try await Task.sleep(for: .milliseconds(20))
        let iCloudFood = try await oats(iCloud)
        try await iCloud.updateFoodEntry(id: entryId, FoodEntryInput(food: iCloudFood, mealTypeId: "lunch", quantity: 150, entryDate: today))

        try StoreTransfer.copy(from: cache.store, to: iCloud.store, account: account)

        XCTAssertEqual(iCloud.store.all(LocalFoodEntry.self).map(\.quantity), [150])
    }

    /// A slow or unreachable server can't hold a screen up past the timeout.
    func testOpeningADayWaitsNoLongerThanTheTimeout() async throws {
        let server = FakeSyncServer()
        let (sync, _) = makeSync(server)
        await sync.syncNow()
        server.delay = .seconds(3)
        let started = Date()

        await sync.refresh(day: Calendar.current.date(byAdding: .day, value: -3, to: today)!, timeout: .milliseconds(200))

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        server.delay = nil
    }

    /// Signing out mid-sync: the old sync mustn't mark the next copy as
    /// fully downloaded.
    func testASyncFromBeforeSignOutRecordsNothing() async throws {
        let server = FakeSyncServer()
        let store = LocalStore(inMemory: true)
        let sync = ServerSync(server: server, storeFor: { _ in store })
        let account = SyncAccount.key(serverURL: serverURL, email: user.email)
        InitialPull.reset(account: account)
        defer { InitialPull.reset(account: account) }
        server.delay = .milliseconds(300)
        sync.activate(user: user, serverURL: serverURL)
        let running = Task { await sync.syncNow() }
        try await Task.sleep(for: .milliseconds(50))

        sync.deactivate(removingCopy: false)
        await running.value
        try await Task.sleep(for: .seconds(2))

        XCTAssertFalse(InitialPull.isDone(account: account))
        XCTAssertNil(sync.lastSyncedAt)
    }

    // MARK: - Signing in out of range

    func testASavedSessionIsOnlyForItsOwnServer() {
        SessionCache.save(user, serverURL: "http://Sparky.local:3010/")
        defer { SessionCache.clear() }
        XCTAssertEqual(SessionCache.user(forServer: "http://sparky.local:3010")?.email, user.email)
        XCTAssertNil(SessionCache.user(forServer: "http://another:3010"))
    }

    /// Out of range with a saved session: straight into the diary, not the
    /// "can't reach the server" screen.
    func testOutOfRangeTheLastSignedInUserOpensTheirDiary() async throws {
        let server = FakeSyncServer()
        let sync = ServerSync(server: server, storeFor: { _ in LocalStore(inMemory: true) })
        let client = ServerModeClient(remote: APIClient(session: StubURLProtocol.session()), sync: sync)
        SessionCache.save(user, serverURL: ServerConfig.urlString)
        defer {
            SessionCache.clear()
            StubURLProtocol.failure = nil
        }
        StubURLProtocol.failure = URLError(.cannotConnectToHost)

        let session = try await client.currentSession()

        XCTAssertEqual(session?.email, user.email)
        XCTAssertTrue(sync.isActive)
    }

    /// A server that accepts the connection and never answers can't hold the
    /// launch for the whole request timeout when a session is saved.
    func testAHungServerOpensTheSavedSessionQuickly() async throws {
        let sync = ServerSync(server: FakeSyncServer(), storeFor: { _ in LocalStore(inMemory: true) })
        let client = ServerModeClient(remote: APIClient(session: StubURLProtocol.session()), sync: sync)
        SessionCache.save(user, serverURL: ServerConfig.urlString)
        StubURLProtocol.hangs = true
        defer { StubURLProtocol.hangs = false }
        let started = Date()

        let session = try await client.currentSession()

        XCTAssertEqual(session?.email, user.email)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testOutOfRangeWithNoSavedSessionStillReportsUnreachable() async throws {
        let sync = ServerSync(server: FakeSyncServer(), storeFor: { _ in LocalStore(inMemory: true) })
        let client = ServerModeClient(remote: APIClient(session: StubURLProtocol.session()), sync: sync)
        SessionCache.clear()
        StubURLProtocol.failure = URLError(.cannotConnectToHost)
        defer { StubURLProtocol.failure = nil }

        do {
            _ = try await client.currentSession()
            XCTFail("with nobody to open as, the app has to say it can't connect")
        } catch {
            XCTAssertTrue(error.isConnectivityFailure)
        }
    }

    /// Everything the screens write in server mode lands on this device
    /// first, even with the server out of range.
    func testWritesThroughTheServerModeClientWorkOffline() async throws {
        let server = FakeSyncServer()
        server.isOffline = true
        let store = LocalStore(inMemory: true)
        let sync = ServerSync(server: server, storeFor: { _ in store })
        sync.activate(user: user, serverURL: serverURL)
        StubURLProtocol.failure = URLError(.notConnectedToInternet)
        defer { StubURLProtocol.failure = nil }
        let client = ServerModeClient(remote: APIClient(session: StubURLProtocol.session()), sync: sync)
        let food = Food(id: "srv-food", name: "Server oats", brand: nil,
                        defaultVariant: FoodVariant(id: "srv-variant", servingSize: 100, servingUnit: "g", calories: 380, protein: 13, carbs: 67, fat: 7))

        try await client.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 100, entryDate: today))
        _ = try await client.logWaterAmount(date: today, milliliters: 250)
        let searched = try await client.searchFoods(query: "Server")

        let day = try await client.dailySummary(date: today)
        XCTAssertEqual(day.foodEntries.count, 1)
        XCTAssertEqual(day.waterIntake, 250, accuracy: 0.5)
        XCTAssertEqual(searched.map(\.id), ["srv-food"], "offline search falls back to this device's foods")
        // A food picked from the server's library is linked to it, so the
        // push won't create a second one there.
        let link = store.link(kind: LocalFood.syncKind, localKey: "srv-food", account: try XCTUnwrap(sync.account))
        XCTAssertEqual(link?.serverVariantId, "srv-variant")
    }
}
