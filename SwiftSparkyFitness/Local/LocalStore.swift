//
//  LocalStore.swift
//  SwiftSparkyFitness
//
//  The SwiftData container behind local-only mode, plus the small amount of
//  seeding that replaces what a fresh server account would have been given.
//
//  Main-actor bound on purpose. Every caller is a view model already isolated
//  to the main actor, the data volume is one person's food diary rather than a
//  shared database, and a `ModelActor` would buy concurrency this screen size
//  cannot spend. If that ever stops being true, the seam to move is this class,
//  not the callers.
//  ponytail: single main-actor context; move to a ModelActor if a background
//  import (a large provider sync) ever needs to write off the main thread.
//

import Foundation
import SwiftData

@MainActor
final class LocalStore {
    static let shared = LocalStore()

    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    /// Set when the store could not be opened at all. The app stays usable in
    /// the sense that it doesn't crash — every read returns empty and the
    /// failure is surfaced rather than looking like "you have logged nothing".
    private(set) var loadFailure: Error?

    private init() {
        let schema = Schema([
            LocalFood.self,
            LocalFoodEntry.self,
            LocalExercise.self,
            LocalExerciseEntry.self,
            LocalWaterEntry.self,
            LocalWaterContainer.self,
            LocalCheckIn.self,
            LocalGoalRow.self,
            LocalPreferences.self,
            LocalMealType.self
        ])

        // `.none` is explicit rather than incidental: SwiftData treats the
        // presence of CloudKit capabilities as permission to sync on its own,
        // and iCloud sync is a separate module that hasn't been designed yet.
        // Without this, adding the entitlement later would silently switch
        // syncing on before anyone decided how conflicts should resolve.
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        do {
            container = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            // A corrupt or unreadable store must not take the app down on
            // launch. In memory, the session is useless but diagnosable; on
            // disk it would be a crash loop with no way to reach Settings.
            loadFailure = error
            container = try! ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            )
        }
        seedIfNeeded()
    }

    /// Test seam: an isolated in-memory store, so local-repository tests never
    /// touch the real one on disk.
    init(inMemory: Bool) {
        let schema = Schema([
            LocalFood.self,
            LocalFoodEntry.self,
            LocalExercise.self,
            LocalExerciseEntry.self,
            LocalWaterEntry.self,
            LocalWaterContainer.self,
            LocalCheckIn.self,
            LocalGoalRow.self,
            LocalPreferences.self,
            LocalMealType.self
        ])
        container = try! ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        )
        seedIfNeeded()
    }

    // MARK: - Fetching

    func all<T: PersistentModel>(_ type: T.Type, sortBy: [SortDescriptor<T>] = []) -> [T] {
        (try? context.fetch(FetchDescriptor<T>(sortBy: sortBy))) ?? []
    }

    func fetch<T: PersistentModel>(_ type: T.Type, where predicate: Predicate<T>, sortBy: [SortDescriptor<T>] = []) -> [T] {
        (try? context.fetch(FetchDescriptor<T>(predicate: predicate, sortBy: sortBy))) ?? []
    }

    func save() {
        try? context.save()
    }

    func insert<T: PersistentModel>(_ model: T) {
        context.insert(model)
        save()
    }

    func delete<T: PersistentModel>(_ model: T) {
        context.delete(model)
        save()
    }

    // MARK: - Seeding

    /// What a fresh server account is handed for free: the four meal
    /// categories and a preferences row. Seeded once, and only when empty, so
    /// a user who hides or renames things doesn't get them resurrected.
    private func seedIfNeeded() {
        if all(LocalMealType.self).isEmpty {
            // Same names and sort orders the server ships, so a diary written
            // here reads the same way as one written against a server.
            let defaults = [("Breakfast", 10), ("Lunch", 20), ("Dinner", 30), ("Snacks", 40)]
            for (name, order) in defaults {
                context.insert(
                    LocalMealType(
                        id: name.lowercased(),
                        name: name,
                        sortOrder: order,
                        isSystemDefault: true
                    )
                )
            }
        }
        if all(LocalPreferences.self).isEmpty {
            context.insert(LocalPreferences())
        }
        save()
    }

    // MARK: - Destroying

    /// Wipes every local row. Used by the "delete local data" control in
    /// Settings, which exists because local mode has no server copy to fall
    /// back on — the user should be able to start over deliberately rather
    /// than only by deleting the app.
    func deleteEverything() throws {
        try context.delete(model: LocalFood.self)
        try context.delete(model: LocalFoodEntry.self)
        try context.delete(model: LocalExercise.self)
        try context.delete(model: LocalExerciseEntry.self)
        try context.delete(model: LocalWaterEntry.self)
        try context.delete(model: LocalWaterContainer.self)
        try context.delete(model: LocalCheckIn.self)
        try context.delete(model: LocalGoalRow.self)
        try context.delete(model: LocalPreferences.self)
        try context.delete(model: LocalMealType.self)
        save()
        seedIfNeeded()
    }
}
