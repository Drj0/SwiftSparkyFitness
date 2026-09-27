//
//  SyncLedgerTests.swift
//  SwiftSparkyFitnessTests
//
//  Step 1 of docs/SYNC_SWITCHING_PLAN.md: the bookkeeping every later switch
//  relies on — edit stamps, tombstones, links, the handoff log — plus the two
//  server-client changes (create returns the id; source/source_id dedupe).
//

import XCTest
import SwiftData
@testable import SwiftSparkyFitness

@MainActor
final class SyncLedgerTests: XCTestCase {

    private let account = SyncAccount.key(serverURL: "http://sparky.local:3010", email: "me@example.com")

    private func makeLocal() -> LocalAPIClient {
        LocalAPIClient(store: LocalStore(inMemory: true))
    }

    private func logOats(_ local: LocalAPIClient, quantity: Double = 100) async throws -> LocalFoodEntry {
        let food = try await local.materializeExternalFood(Food(
            id: "oats", name: "Oats", brand: nil,
            defaultVariant: FoodVariant(id: "oats-v", servingSize: 100, servingUnit: "g", calories: 380, protein: 13, carbs: 67, fat: 7)
        ))
        let id = try await local.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "breakfast", quantity: quantity, entryDate: Date()))
        return try XCTUnwrap(local.store.fetch(LocalFoodEntry.self, where: #Predicate { $0.id == id }).first)
    }

    // MARK: - Edit stamps

    func testCreatingAnEntryStampsItAndReturnsItsId() async throws {
        let local = makeLocal()
        let before = Date()
        let entry = try await logOats(local)
        XCTAssertGreaterThanOrEqual(entry.updatedAt, before)
    }

    func testEditingRestampsOnlyTheEditedRow() async throws {
        let local = makeLocal()
        let edited = try await logOats(local)
        let untouched = try await logOats(local, quantity: 50)
        let untouchedStamp = untouched.updatedAt
        let firstStamp = edited.updatedAt

        try await Task.sleep(for: .milliseconds(20))
        let food = try await local.materializeExternalFood(Food(
            id: "oats", name: "Oats", brand: nil,
            defaultVariant: FoodVariant(id: "oats-v", servingSize: 100, servingUnit: "g", calories: 380, protein: 13, carbs: 67, fat: 7)
        ))
        try await local.updateFoodEntry(id: edited.id, FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 200, entryDate: Date()))

        XCTAssertGreaterThan(edited.updatedAt, firstStamp)
        XCTAssertEqual(untouched.updatedAt, untouchedStamp)
    }

    // MARK: - Tombstones

    func testDeletingALinkedRowLeavesATombstone() async throws {
        let local = makeLocal()
        let entry = try await logOats(local)
        let key = entry.id
        local.store.setLink(entry, serverId: "srv-1", account: account)

        try await local.deleteFoodEntry(id: key)

        let tombstones = local.store.tombstones(kind: LocalFoodEntry.syncKind)
        XCTAssertEqual(tombstones.map(\.localKey), [key])
        // The link stays: it is how the next switch finds the server row to delete.
        XCTAssertEqual(local.store.link(kind: LocalFoodEntry.syncKind, localKey: key, account: account)?.serverId, "srv-1")
    }

    func testDeletingAnUnlinkedRowLeavesNoTombstone() async throws {
        let local = makeLocal()
        let entry = try await logOats(local)
        try await local.deleteFoodEntry(id: entry.id)
        XCTAssertTrue(local.store.all(LocalTombstone.self).isEmpty)
    }

    func testRecreatingATombstonedKeyClearsTheTombstone() {
        let store = LocalStore(inMemory: true)
        let goal = LocalGoalRow(dayKey: "2026-09-01", rawJSON: Data())
        store.insert(goal)
        store.setLink(goal, serverId: "g-1", account: account)
        store.delete(goal)
        XCTAssertEqual(store.tombstones(kind: LocalGoalRow.syncKind).count, 1)

        store.insert(LocalGoalRow(dayKey: "2026-09-01", rawJSON: Data()))

        XCTAssertTrue(store.tombstones(kind: LocalGoalRow.syncKind).isEmpty)
    }

    func testDeleteAndReinsertInOneSaveIsAnEditNotADelete() {
        let store = LocalStore(inMemory: true)
        let goal = LocalGoalRow(dayKey: "2026-09-02", rawJSON: Data())
        store.insert(goal)
        store.setLink(goal, serverId: "g-2", account: account)

        store.context.delete(goal)
        store.context.insert(LocalGoalRow(dayKey: "2026-09-02", rawJSON: Data([1])))
        XCTAssertTrue(store.save())

        XCTAssertTrue(store.tombstones(kind: LocalGoalRow.syncKind).isEmpty)
    }

    /// Stands in for a save that failed and is retried: its deletes are seen
    /// twice. Either way a key gets one tombstone.
    func testAKeyNeverGetsASecondTombstone() {
        let store = LocalStore(inMemory: true)
        let goal = LocalGoalRow(dayKey: "2026-09-03", rawJSON: Data())
        store.insert(goal)
        store.setLink(goal, serverId: "g-3", account: account)
        store.context.insert(LocalTombstone(kind: LocalGoalRow.syncKind, localKey: "2026-09-03"))

        store.delete(goal)

        XCTAssertEqual(store.tombstones(kind: LocalGoalRow.syncKind).count, 1)
    }

    /// Stamping lives in `save()`; an autosave would bypass it.
    func testAutosaveIsOffSoEverySaveIsStamped() throws {
        XCTAssertFalse(LocalStore(inMemory: true).context.autosaveEnabled)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("autosave-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(try LocalStore(url: url).context.autosaveEnabled)
    }

    // MARK: - Links

    /// Two devices can each link one row before seeing the other's link.
    func testTheNewestOfTwoLinksWins() {
        let store = LocalStore(inMemory: true)
        store.insert(LocalSyncLink(kind: "foodEntry", localKey: "k", serverId: "old", serverAccount: account, linkedAt: Date(timeIntervalSinceNow: -60)))
        store.insert(LocalSyncLink(kind: "foodEntry", localKey: "k", serverId: "new", serverAccount: account))
        XCTAssertEqual(store.link(kind: "foodEntry", localKey: "k", account: account)?.serverId, "new")
    }

    func testALinkIsPerAccountAndRelinkingReplacesIt() async throws {
        let local = makeLocal()
        let entry = try await logOats(local)
        let other = SyncAccount.key(serverURL: "http://other:3010", email: "me@example.com")

        local.store.setLink(entry, serverId: "srv-1", account: account)
        local.store.setLink(entry, serverId: "srv-2", account: account)
        local.store.setLink(entry, serverId: "elsewhere", account: other)

        XCTAssertEqual(local.store.links(kind: LocalFoodEntry.syncKind, account: account).map(\.serverId), ["srv-2"])
        XCTAssertEqual(local.store.link(for: entry, account: other)?.serverId, "elsewhere")
    }

    func testAccountKeyIgnoresCaseWhitespaceAndTrailingSlashes() {
        XCTAssertEqual(
            SyncAccount.key(serverURL: " HTTP://Sparky.local:3010// ", email: " Me@Example.com"),
            SyncAccount.key(serverURL: "http://sparky.local:3010", email: "me@example.com")
        )
        XCTAssertNotEqual(
            SyncAccount.key(serverURL: "http://sparky.local:3010", email: "me@example.com"),
            SyncAccount.key(serverURL: "http://sparky.local:3010", email: "you@example.com")
        )
    }

    // MARK: - Handoffs

    func testTheLatestHandoffDecidesTheSyncedHome() {
        let store = LocalStore(inMemory: true)
        XCTAssertNil(store.syncedHome)

        let earlier = store.recordHandoff(from: .server, to: .local, serverAccount: account)
        earlier.date = Date(timeIntervalSinceNow: -60)
        store.save()
        store.recordHandoff(from: .local, to: .server, serverAccount: account)

        XCTAssertEqual(store.syncedHome, .server)
        XCTAssertEqual(store.latestHandoff?.fromMode, AppMode.local.rawValue)
    }

    // MARK: - Wipe

    func testWipeClearsLinksAndTombstonesWithoutTombstoningAndKeepsHandoffs() async throws {
        let local = makeLocal()
        let kept = try await logOats(local)
        let deleted = try await logOats(local, quantity: 20)
        local.store.setLink(kept, serverId: "a", account: account)
        local.store.setLink(deleted, serverId: "b", account: account)
        try await local.deleteFoodEntry(id: deleted.id)
        local.store.recordHandoff(from: .server, to: .local, serverAccount: account)

        try local.store.deleteEverything()

        XCTAssertTrue(local.store.all(LocalFoodEntry.self).isEmpty)
        XCTAssertTrue(local.store.all(LocalSyncLink.self).isEmpty)
        XCTAssertTrue(local.store.all(LocalTombstone.self).isEmpty)
        XCTAssertEqual(local.store.all(LocalHandoff.self).count, 1)
        XCTAssertNil(local.store.lastSaveError)
    }

    // MARK: - Upgrade from the pre-tracking schema

    /// A store written before this step — no `updatedAt`, none of the three
    /// ledger models — must open under the new schema by lightweight
    /// migration, keep its rows, and read them as never stamped.
    func testAStoreFromBeforeTrackingOpensAndReadsAsNeverStamped() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pre-tracking-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }

        // In a pool so the old container is fully released before the new
        // schema opens the same file.
        try autoreleasepool {
            let schema = Schema([PreTracking.LocalFood.self])
            let old = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
            let context = ModelContext(old)
            context.insert(PreTracking.LocalFood(id: "legacy", name: "Legacy oats"))
            try context.save()
        }

        let store = try LocalStore(url: url)
        let food = try XCTUnwrap(store.fetch(LocalFood.self, where: #Predicate { $0.id == "legacy" }).first)
        XCTAssertEqual(food.name, "Legacy oats")
        XCTAssertEqual(food.updatedAt, .distantPast)

        store.setLink(food, serverId: "srv-legacy", account: account)
        XCTAssertEqual(store.link(for: food, account: account)?.serverId, "srv-legacy")
    }

    // MARK: - Server client

    func testCreateFoodEntryReturnsTheServerIdAndSendsSourceOnlyWhenSet() async throws {
        let client = APIClient(session: StubURLProtocol.session())
        let food = Food(id: "f", name: "Oats", brand: nil,
                        defaultVariant: FoodVariant(id: "v", servingSize: 100, servingUnit: "g", calories: 380, protein: 13, carbs: 67, fat: 7))

        StubURLProtocol.respond(json: #"{"id":"server-entry-1","meal_type_id":"m"}"#, status: 201)
        let tagged = try await client.createFoodEntry(FoodEntryInput(
            food: food, mealTypeId: "m", quantity: 100, entryDate: Date(), source: "ios_local", sourceId: "local-uuid"
        ))
        XCTAssertEqual(tagged, "server-entry-1")
        let taggedBody = try XCTUnwrap(StubURLProtocol.lastBody)
        XCTAssertEqual(taggedBody["source"] as? String, "ios_local")
        XCTAssertEqual(taggedBody["source_id"] as? String, "local-uuid")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")

        StubURLProtocol.respond(json: #"{"id":"server-entry-2"}"#, status: 201)
        _ = try await client.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "m", quantity: 100, entryDate: Date()))
        let plainBody = try XCTUnwrap(StubURLProtocol.lastBody)
        XCTAssertNil(plainBody["source"])
        XCTAssertNil(plainBody["source_id"])
        XCTAssertEqual(plainBody["food_id"] as? String, "f")
    }
}

/// The schema as it shipped before Step 1, for the upgrade test. Only the
/// entity name and stored properties matter to migration.
enum PreTracking {
    @Model
    final class LocalFood {
        var id: String = UUID().uuidString
        var name: String = ""
        var brand: String?
        var servingSize: Double = 100
        var servingUnit: String = "g"
        var calories: Double = 0
        var protein: Double = 0
        var carbs: Double = 0
        var fat: Double = 0
        var isCustom: Bool = true
        var lastUsedAt: Date?
        var usageCount: Int = 0

        init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }
}

/// Answers every request with one canned response and remembers the last
/// request, body decoded, for assertions.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (Data, Int) = (Data(), 200)
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: [String: Any]?

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func respond(json: String, status: Int) {
        response = (Data(json.utf8), status)
        lastRequest = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Set to answer every request as if the server were out of range.
    nonisolated(unsafe) static var failure: URLError?

    override func startLoading() {
        Self.lastRequest = request
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        // URLSession hands a protocol the body as a stream, not httpBody.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            Self.lastBody = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        let (data, status) = Self.response
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
