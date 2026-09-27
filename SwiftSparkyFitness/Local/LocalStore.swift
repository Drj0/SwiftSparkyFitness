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
import OSLog
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

    /// Set when the store opened but *without* CloudKit, having failed to
    /// open with it. The diary works; it just isn't syncing, and Settings
    /// says so rather than claiming a sync that will never happen.
    private(set) var cloudKitSetupFailure: Error?

    /// Syncing is on whenever the store actually opened against CloudKit.
    /// Reads as false in tests and in the fallback paths above.
    var isCloudKitEnabled: Bool { loadFailure == nil && cloudKitSetupFailure == nil }

    /// The one place this identifier is written down. It must match the
    /// entitlements file exactly; a mismatch fails at code-signing rather
    /// than at runtime, which is the good outcome.
    static let cloudKitContainerIdentifier = "iCloud.drj.SwiftSparkyFitness"

    /// Every model in the store. Additions here are automatic lightweight
    /// migrations as long as they follow LocalModels' CloudKit rules — and
    /// must be deployed to the Production CloudKit schema before release.
    static let schema = Schema([
        LocalFood.self,
        LocalFoodEntry.self,
        LocalExercise.self,
        LocalExerciseEntry.self,
        LocalWaterEntry.self,
        LocalWaterContainer.self,
        LocalCheckIn.self,
        LocalGoalRow.self,
        LocalPreferences.self,
        LocalMealType.self,
        LocalSyncLink.self,
        LocalTombstone.self,
        LocalHandoff.self
    ])

    /// The most recent save that failed, cleared by the next one that
    /// succeeds. Saves used to be `try?` and vanish; a full disk then looked
    /// exactly like a successful log.
    private(set) var lastSaveError: Error?

    private init() {
        let schema = Self.schema

        // Module 11: the store now mirrors to CloudKit. The container is
        // named rather than left to `.automatic`, which picks whichever
        // identifier appears first in the entitlements — with one container
        // the two agree, and naming it means adding a second one later can't
        // silently move the user's diary to a different database.
        //
        // Module 10 built the schema for this: no `@Attribute(.unique)`, no
        // relationships, every property defaulted. CloudKit cannot enforce
        // uniqueness and requires optional relationships, and its schemas are
        // additive-only once promoted, so paying that cost up front is what
        // makes this a one-line change rather than a migration.
        let cloudConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private(Self.cloudKitContainerIdentifier)
        )

        do {
            container = try ModelContainer(for: schema, configurations: cloudConfiguration)
        } catch {
            // Falling straight to memory here would be the wrong failure. The
            // likeliest reason this throws is the CloudKit side — no
            // entitlement in this build, a container that isn't provisioned,
            // a device that can't reach iCloud at setup — and none of that is
            // a reason to stop the user reaching their own on-disk diary. So
            // try again with syncing off before giving up on disk entirely.
            cloudKitSetupFailure = error
            do {
                container = try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(
                        schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none
                    )
                )
            } catch {
                // Now it really is the store itself. A corrupt or unreadable
                // one must not take the app down on launch: in memory the
                // session is useless but diagnosable; on disk it would be a
                // crash loop with no way to reach Settings.
                loadFailure = error
                container = try! ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(
                        schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none
                    )
                )
            }
        }
        prepareContext()
    }

    /// Test seam: an isolated in-memory store, so local-repository tests never
    /// touch the real one on disk.
    init(inMemory: Bool) {
        let schema = Self.schema
        container = try! ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        )
        prepareContext()
    }

    /// Test seam: an on-disk store at `url`, so a store written by an older
    /// schema can be reopened by this one — the upgrade path real devices take.
    init(url: URL) throws {
        let schema = Self.schema
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        )
        prepareContext()
    }

    /// Autosave off: every write saves explicitly, and `save()` is where
    /// edits are stamped and deletes tombstoned. An autosave that ran first
    /// would persist a change with neither — silently, and only in whatever
    /// future write path forgot to save synchronously.
    private func prepareContext() {
        context.autosaveEnabled = false
        seedIfNeeded()
    }

    // MARK: - Fetching

    func all<T: PersistentModel>(_ type: T.Type, sortBy: [SortDescriptor<T>] = []) -> [T] {
        (try? context.fetch(FetchDescriptor<T>(sortBy: sortBy))) ?? []
    }

    func fetch<T: PersistentModel>(_ type: T.Type, where predicate: Predicate<T>, sortBy: [SortDescriptor<T>] = []) -> [T] {
        (try? context.fetch(FetchDescriptor<T>(predicate: predicate, sortBy: sortBy))) ?? []
    }

    /// Every write in the app ends here, synchronously on the main actor, so
    /// this is the one place edits are stamped and deletes remembered: no
    /// autosave can run between a write and its save. Rows arriving from
    /// CloudKit are merged by the mirroring context, not saved through here,
    /// so they keep the other device's stamp.
    ///
    /// Returns false, and keeps the error in `lastSaveError`, when the save
    /// failed — a full disk, most likely. Callers that must not carry on
    /// after a lost write (the switching flows) check it; everyday logging
    /// keeps the old fire-and-forget shape.
    @discardableResult
    func save() -> Bool {
        trackPendingChanges()
        do {
            try context.save()
            lastSaveError = nil
            return true
        } catch {
            lastSaveError = error
            Self.logger.error("Local save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static let logger = Logger(subsystem: "drj.SwiftSparkyFitness", category: "LocalStore")

    /// Stamps inserted and edited rows, and tombstones deleted rows that have
    /// a server copy. Batch deletes (`delete(model:)`, used only by the wipe)
    /// bypass this on purpose: starting over locally mustn't delete anything
    /// on a server.
    ///
    /// Invariant: a tombstone exists only for a key with no live row. A row
    /// re-created under a tombstoned key (a goal saved again for its day)
    /// clears the tombstone, and a delete and re-insert of one key in the same
    /// save is an edit, not a delete.
    private func trackPendingChanges() {
        let now = Date()
        var inserted: Set<String> = []
        for model in context.insertedModelsArray {
            guard let row = model as? any SyncTracked else { continue }
            row.updatedAt = now
            let kind = type(of: row).syncKind
            let key = row.syncKey
            inserted.insert("\(kind)|\(key)")
            for stale in fetch(LocalTombstone.self, where: #Predicate { $0.kind == kind && $0.localKey == key }) {
                context.delete(stale)
            }
        }
        for model in context.changedModelsArray {
            (model as? any SyncTracked)?.updatedAt = now
        }
        for model in context.deletedModelsArray {
            guard let row = model as? any SyncTracked else { continue }
            let kind = type(of: row).syncKind
            let key = row.syncKey
            guard !inserted.contains("\(kind)|\(key)") else { continue }
            let linked = !fetch(LocalSyncLink.self, where: #Predicate { $0.kind == kind && $0.localKey == key }).isEmpty
            // A save that failed leaves its deletes pending, and the retry
            // passes through here again — one tombstone per key regardless.
            let alreadyTombstoned = !fetch(LocalTombstone.self, where: #Predicate { $0.kind == kind && $0.localKey == key }).isEmpty
            if linked && !alreadyTombstoned {
                context.insert(LocalTombstone(kind: kind, localKey: key, deletedAt: now))
            }
        }
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
        // Links and tombstones describe rows that no longer exist, so they go
        // too — without tombstones, which is what keeps a local restart from
        // deleting the server's copy. The handoff log stays: it is history of
        // where the diary lived, not diary data.
        try context.delete(model: LocalSyncLink.self)
        try context.delete(model: LocalTombstone.self)
        // The callers report a failed wipe; a swallowed save would let them
        // say "deleted" over a diary that is still there. Rolled back so the
        // queued deletes don't complete on the next unrelated save — after
        // the user was told it failed, and with nothing reseeded.
        if !save() {
            context.rollback()
            if let error = lastSaveError { throw error }
        }
        seedIfNeeded()
    }
}
