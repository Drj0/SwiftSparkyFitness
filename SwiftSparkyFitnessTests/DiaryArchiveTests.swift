//
//  DiaryArchiveTests.swift
//  SwiftSparkyFitnessTests
//
//  Step 2 of docs/SYNC_SWITCHING_PLAN.md: the diary file. A restore merges —
//  never deletes, never rolls back a newer edit — so it is safe to run on any
//  device, any number of times.
//

import XCTest
import SwiftData
@testable import SwiftSparkyFitness

@MainActor
final class DiaryArchiveTests: XCTestCase {

    private func makeLocal() -> LocalAPIClient {
        LocalAPIClient(store: LocalStore(inMemory: true))
    }

    private let day = LocalDay.date("2026-09-10")!

    private func oats(_ local: LocalAPIClient) async throws -> Food {
        try await local.materializeExternalFood(Food(
            id: "oats", name: "Oats", brand: "Acme",
            defaultVariant: FoodVariant(id: "oats-v", servingSize: 100, servingUnit: "g", calories: 380, protein: 13, carbs: 67, fat: 7)
        ))
    }

    /// A diary touching every kind of row the file carries.
    private func seedDiary(_ local: LocalAPIClient) async throws {
        let food = try await oats(local)
        let lunch = try await local.createMealType(name: "Second breakfast", sortOrder: 15)
        try await local.createFoodEntry(FoodEntryInput(food: food, mealTypeId: lunch.id, quantity: 150, entryDate: day))
        let lifting = try await local.createCustomExercise(CustomExerciseInput(name: "Squat", category: "strength", modality: .weightReps))
        _ = try await local.createExerciseEntry(ExerciseEntryInput(
            exerciseId: lifting.id, modality: .weightReps, entryDate: day, durationMinutes: 20, caloriesBurned: 150,
            sets: [ExerciseSetInput(setNumber: 1, setType: "Working Set", reps: 5, weight: 100, rpe: 8, notes: nil)]
        ))
        _ = try await local.logWaterAmount(date: day, milliliters: 750)
        _ = try await local.upsertBodyMeasurements(BodyMeasurementsInput(date: day, values: [.weight: 72.5, .waist: 80]))
        _ = try await local.updateUserPreference(.weight, to: "lbs")
        _ = try await local.createWaterContainer(WaterContainerInput(name: "Bottle", volume: 750, unit: "ml", servingsPerContainer: 1))
    }

    private func roundTrip(_ archive: DiaryArchive) throws -> DiaryArchive {
        try DiaryArchive.decode(archive.encoded())
    }

    // MARK: - Round trip

    func testARestoredDiaryReadsTheSameAsTheOriginal() async throws {
        let source = makeLocal()
        try await seedDiary(source)
        let archive = try roundTrip(DiaryArchive(from: source.store))

        let destination = makeLocal()
        let result = try archive.restore(into: destination.store)
        XCTAssertGreaterThan(result.added, 0)
        XCTAssertEqual(result.earliestDay, day)

        let original = try await source.dailySummary(date: day)
        let restored = try await destination.dailySummary(date: day)
        XCTAssertEqual(restored.foodEntries.map(\.id), original.foodEntries.map(\.id))
        XCTAssertEqual(restored.foodEntries.map(\.mealType), ["Second breakfast"])
        XCTAssertEqual(restored.calorieBalance.eaten, original.calorieBalance.eaten, accuracy: 0.01)
        XCTAssertEqual(restored.waterIntake, original.waterIntake, accuracy: 0.01)
        XCTAssertEqual(restored.exerciseSessions.first?.setsList.first?.weight, 100)
        let weight = try await destination.bodyMeasurements(date: day).weight
        XCTAssertEqual(weight, 72.5)
        let prefs = try await destination.userPreferences()
        XCTAssertEqual(prefs.defaultWeightUnit, "lbs")
        let containers = try await destination.waterContainers()
        XCTAssertTrue(containers.contains { $0.name == "Bottle" })
        XCTAssertEqual(destination.store.all(LocalFood.self).first { $0.id == "oats" }?.brand, "Acme")
    }

    func testRestoringTheSameFileTwiceChangesNothing() async throws {
        let source = makeLocal()
        try await seedDiary(source)
        let archive = try roundTrip(DiaryArchive(from: source.store))
        let destination = makeLocal()
        _ = try archive.restore(into: destination.store)
        let entries = destination.store.all(LocalFoodEntry.self).count

        let again = try archive.restore(into: destination.store)

        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.updated, 0)
        XCTAssertEqual(destination.store.all(LocalFoodEntry.self).count, entries)
    }

    /// Restored rows keep the file's stamp; stamping them "now" would make
    /// every restored row look like a fresh edit to the next sync.
    func testRestoredRowsKeepTheirOwnStamps() async throws {
        let source = makeLocal()
        try await seedDiary(source)
        let original = try XCTUnwrap(source.store.all(LocalFoodEntry.self).first)
        let archive = try roundTrip(DiaryArchive(from: source.store))

        let destination = makeLocal()
        _ = try archive.restore(into: destination.store)

        let restored = try XCTUnwrap(destination.store.all(LocalFoodEntry.self).first)
        XCTAssertEqual(restored.updatedAt.timeIntervalSince1970, original.updatedAt.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - Merge rules

    func testAnEditMadeHereAfterTheExportIsKept() async throws {
        let local = makeLocal()
        try await seedDiary(local)
        let archive = try roundTrip(DiaryArchive(from: local.store))
        try await Task.sleep(for: .milliseconds(1100)) // past the file's second-resolution stamps
        let entry = try XCTUnwrap(local.store.all(LocalFoodEntry.self).first)
        let food = try await oats(local)
        try await local.updateFoodEntry(id: entry.id, FoodEntryInput(food: food, mealTypeId: entry.mealTypeId, quantity: 300, entryDate: day))

        let result = try archive.restore(into: local.store)

        XCTAssertEqual(local.store.all(LocalFoodEntry.self).first?.quantity, 300)
        XCTAssertGreaterThan(result.kept, 0)
    }

    func testANewerEditInTheFileWins() async throws {
        let local = makeLocal()
        try await seedDiary(local)
        var archive = try roundTrip(DiaryArchive(from: local.store))
        archive.foodEntries[0].quantity = 999
        archive.foodEntries[0].updatedAt = Date(timeIntervalSinceNow: 3600)

        let result = try archive.restore(into: local.store)

        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(local.store.all(LocalFoodEntry.self).first?.quantity, 999)
    }

    func testRestoringNeverDeletesRowsOnlyThisDeviceHas() async throws {
        let empty = try roundTrip(DiaryArchive(from: makeLocal().store))
        let local = makeLocal()
        try await seedDiary(local)
        let before = local.store.all(LocalFoodEntry.self).count

        _ = try empty.restore(into: local.store)

        XCTAssertEqual(local.store.all(LocalFoodEntry.self).count, before)
        XCTAssertEqual(local.store.all(LocalCheckIn.self).count, 1)
    }

    /// Both sides keep one check-in per day, whatever id each copy has.
    func testACheckInMergesIntoTheSameDaysRow() async throws {
        let source = makeLocal()
        _ = try await source.upsertBodyMeasurements(BodyMeasurementsInput(date: day, values: [.weight: 70]))
        var archive = try roundTrip(DiaryArchive(from: source.store))
        archive.checkIns[0].updatedAt = Date(timeIntervalSinceNow: 3600)

        let destination = makeLocal()
        _ = try await destination.upsertBodyMeasurements(BodyMeasurementsInput(date: day, values: [.weight: 65]))
        _ = try archive.restore(into: destination.store)

        XCTAssertEqual(destination.store.all(LocalCheckIn.self).count, 1)
        let weight = try await destination.bodyMeasurements(date: day).weight
        XCTAssertEqual(weight, 70)
    }

    /// Settings changed before stamping existed read as never-stamped, the
    /// same as a fresh device's seeded defaults. The file must still win.
    func testPreTrackingSettingsBeatAFreshDevicesDefaults() async throws {
        let source = makeLocal()
        _ = try await source.updateUserPreference(.weight, to: "lbs")
        let prefs = try XCTUnwrap(source.store.all(LocalPreferences.self).first)
        prefs.updatedAt = .distantPast
        source.store.preservingStamps { source.store.save() }
        let archive = try roundTrip(DiaryArchive(from: source.store))

        let fresh = makeLocal()
        let first = try archive.restore(into: fresh.store)
        let restored = try await fresh.userPreferences()
        XCTAssertEqual(restored.defaultWeightUnit, "lbs")
        XCTAssertGreaterThan(first.updated, 0)

        let again = try archive.restore(into: fresh.store)
        XCTAssertEqual(again.updated, 0)
    }

    /// A server-linked entry deleted after the export has a tombstone newer
    /// than the file's copy; restoring must not resurrect it (or clear the
    /// tombstone that will delete its server copy).
    func testRestoringDoesNotResurrectALinkedRowDeletedSince() async throws {
        let local = makeLocal()
        try await seedDiary(local)
        let entry = try XCTUnwrap(local.store.all(LocalFoodEntry.self).first)
        let entryId = entry.id
        local.store.setLink(entry, serverId: "srv", account: "acct")
        let archive = try roundTrip(DiaryArchive(from: local.store))
        try await Task.sleep(for: .milliseconds(1100))
        try await local.deleteFoodEntry(id: entryId)

        _ = try archive.restore(into: local.store)

        XCTAssertTrue(local.store.fetch(LocalFoodEntry.self, where: #Predicate { $0.id == entryId }).isEmpty)
        XCTAssertEqual(local.store.tombstones(kind: LocalFoodEntry.syncKind).map(\.localKey), [entryId])
    }

    /// A restore ends in one save, and that save once read the tombstones
    /// once per restored row: a two-year diary (~4,900 rows) held the main
    /// thread for 16 s in a release build, in Settings' restore and in
    /// moving a server diary to this iPhone. Now one read per save. On disk,
    /// like the real store: in memory each read is too cheap to show it.
    func testRestoringALargeDiaryIsQuick() async throws {
        let source = makeLocal()
        try await seedDiary(source)
        var archive = DiaryArchive(from: source.store)
        let entry = try XCTUnwrap(archive.foodEntries.first)
        archive.foodEntries = (0..<3000).map { index in
            var copy = entry
            copy.id = "bulk-\(index)"
            return copy
        }

        let directory = URL.temporaryDirectory.appending(path: "restore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let destination = LocalAPIClient(store: try LocalStore(url: directory.appending(path: "diary.store")))
        let start = Date()
        let result = try archive.restore(into: destination.store)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThanOrEqual(result.added, 3000)
        XCTAssertEqual(destination.store.all(LocalFoodEntry.self).count, 3000)
        XCTAssertLessThan(elapsed, 1.5, "restoring 3,000 entries took \(Int(elapsed * 1000)) ms")
    }

    // MARK: - Bad files

    func testAFileThatIsntADiaryIsRefused() {
        XCTAssertThrowsError(try DiaryArchive.decode(Data(#"{"hello":"world"}"#.utf8))) { error in
            XCTAssertEqual(error as? DiaryArchive.ArchiveError, .notADiary)
        }
        XCTAssertThrowsError(try DiaryArchive.decode(Data("not json".utf8)))
    }

    func testAFileFromANewerAppIsRefusedRatherThanHalfRead() {
        let json = #"{"format":"sparkyfitness-diary","version":99,"exportedAt":"2026-09-28T00:00:00Z"}"#
        XCTAssertThrowsError(try DiaryArchive.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? DiaryArchive.ArchiveError, .tooNew(99))
        }
    }
}

