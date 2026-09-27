//
//  StoreTransfer.swift
//  SwiftSparkyFitness
//
//  Moves server mode's copy of the diary into this device's own (iCloud)
//  diary. See docs/SYNC_SWITCHING_PLAN.md, "Server → iCloud".
//
//  Needs no server: the copy is already on this device. So the same move
//  works whether the server is fine, out of range, or gone for good — in the
//  last two cases it carries everything up to the last sync, plus whatever
//  was logged here since.
//
//  A merge, like a restore: the newer copy of each row wins, and nothing only
//  the destination has is removed. Rows are matched by the server row both
//  sides link to, not only by id — a row this device's diary sent to the
//  server earlier keeps its own id there, while the copy knows it under the
//  server's — so a round trip never doubles anything. The account's links
//  travel with the rows, so moving back to the same server later sends only
//  what changed; deletes the server hasn't heard about yet travel too.
//

import Foundation
import SwiftData

@MainActor
enum StoreTransfer {
    @discardableResult
    static func copy(from source: LocalStore, to destination: LocalStore, account: String) throws -> DiaryArchive.RestoreResult {
        // Source key → destination key, wherever both link to one server row.
        func keyMap(_ kind: String) -> [String: String] {
            var destinationKey: [String: String] = [:]
            for link in destination.links(kind: kind, account: account) { destinationKey[link.serverId] = link.localKey }
            var map: [String: String] = [:]
            for link in source.links(kind: kind, account: account) {
                if let key = destinationKey[link.serverId], key != link.localKey { map[link.localKey] = key }
            }
            return map
        }
        let maps: [String: [String: String]] = Dictionary(uniqueKeysWithValues: [
            LocalFood.syncKind, LocalFoodEntry.syncKind, LocalExercise.syncKind, LocalExerciseEntry.syncKind,
            LocalWaterEntry.syncKind, LocalCheckIn.syncKind, LocalMealType.syncKind
        ].map { ($0, keyMap($0)) })
        func mapped(_ kind: String, _ key: String) -> String { maps[kind]?[key] ?? key }

        var archive = DiaryArchive(from: source)
        for index in archive.foods.indices { archive.foods[index].id = mapped(LocalFood.syncKind, archive.foods[index].id) }
        for index in archive.foodEntries.indices {
            archive.foodEntries[index].id = mapped(LocalFoodEntry.syncKind, archive.foodEntries[index].id)
            archive.foodEntries[index].foodId = mapped(LocalFood.syncKind, archive.foodEntries[index].foodId)
            archive.foodEntries[index].mealTypeId = mapped(LocalMealType.syncKind, archive.foodEntries[index].mealTypeId)
        }
        for index in archive.exercises.indices { archive.exercises[index].id = mapped(LocalExercise.syncKind, archive.exercises[index].id) }
        for index in archive.exerciseEntries.indices {
            archive.exerciseEntries[index].id = mapped(LocalExerciseEntry.syncKind, archive.exerciseEntries[index].id)
            archive.exerciseEntries[index].exerciseId = mapped(LocalExercise.syncKind, archive.exerciseEntries[index].exerciseId)
        }
        for index in archive.water.indices { archive.water[index].id = mapped(LocalWaterEntry.syncKind, archive.water[index].id) }
        for index in archive.checkIns.indices { archive.checkIns[index].id = mapped(LocalCheckIn.syncKind, archive.checkIns[index].id) }
        for index in archive.mealTypes.indices { archive.mealTypes[index].id = mapped(LocalMealType.syncKind, archive.mealTypes[index].id) }
        // Containers are the server's in server mode; this diary keeps its own.
        archive.waterContainers = []

        let result = try archive.restore(into: destination)

        try destination.applyingRemoteChanges {
            for link in source.all(LocalSyncLink.self) where link.serverAccount == account {
                let key = mapped(link.kind, link.localKey)
                guard rowStamp(kind: link.kind, key: key, in: destination) != nil else { continue }
                destination.setLink(kind: link.kind, localKey: key, serverId: link.serverId, account: account,
                                    serverVariantId: link.serverVariantId, version: link.linkedAt, save: false)
            }
            // Deleted in the copy and not yet on the server: deleted here too
            // unless this diary edited the row after that delete, and still
            // owed to the server if the diary ever goes back.
            for tombstone in source.all(LocalTombstone.self) where ServerPush.deletableKinds.contains(tombstone.kind) {
                let kind = tombstone.kind
                let key = mapped(kind, tombstone.localKey)
                if let stamp = rowStamp(kind: kind, key: key, in: destination) {
                    guard stamp <= tombstone.deletedAt else { continue }
                    deleteRow(kind: kind, key: key, in: destination)
                }
                if let link = source.link(kind: kind, localKey: tombstone.localKey, account: account) {
                    destination.setLink(kind: kind, localKey: key, serverId: link.serverId, account: account,
                                        serverVariantId: link.serverVariantId, version: link.linkedAt, save: false)
                }
                if destination.fetch(LocalTombstone.self, where: #Predicate { $0.kind == kind && $0.localKey == key }).isEmpty {
                    destination.context.insert(LocalTombstone(kind: kind, localKey: key, deletedAt: tombstone.deletedAt))
                }
            }
            guard destination.save() else {
                destination.context.rollback()
                throw ServerPush.LocalSaveFailure(underlying: destination.lastSaveError)
            }
        }
        return result
    }

    /// The row's stamp, or nil when there's no such row.
    private static func rowStamp(kind: String, key: String, in store: LocalStore) -> Date? {
        switch kind {
        case LocalFood.syncKind: return store.fetch(LocalFood.self, where: #Predicate { $0.id == key }).first?.updatedAt
        case LocalFoodEntry.syncKind: return store.fetch(LocalFoodEntry.self, where: #Predicate { $0.id == key }).first?.updatedAt
        case LocalExercise.syncKind: return store.fetch(LocalExercise.self, where: #Predicate { $0.id == key }).first?.updatedAt
        case LocalExerciseEntry.syncKind: return store.fetch(LocalExerciseEntry.self, where: #Predicate { $0.id == key }).first?.updatedAt
        case LocalWaterEntry.syncKind: return store.fetch(LocalWaterEntry.self, where: #Predicate { $0.id == key }).first?.updatedAt
        case LocalCheckIn.syncKind: return store.fetch(LocalCheckIn.self, where: #Predicate { $0.id == key }).first?.updatedAt
        case LocalGoalRow.syncKind: return store.fetch(LocalGoalRow.self, where: #Predicate { $0.dayKey == key }).first?.updatedAt
        case LocalPreferences.syncKind: return store.fetch(LocalPreferences.self, where: #Predicate { $0.id == key }).first?.updatedAt
        case LocalMealType.syncKind: return store.fetch(LocalMealType.self, where: #Predicate { $0.id == key }).first?.updatedAt
        default: return nil
        }
    }

    private static func deleteRow(kind: String, key: String, in store: LocalStore) {
        switch kind {
        case LocalFoodEntry.syncKind: store.fetch(LocalFoodEntry.self, where: #Predicate { $0.id == key }).forEach(store.context.delete)
        case LocalExerciseEntry.syncKind: store.fetch(LocalExerciseEntry.self, where: #Predicate { $0.id == key }).forEach(store.context.delete)
        case LocalWaterEntry.syncKind: store.fetch(LocalWaterEntry.self, where: #Predicate { $0.id == key }).forEach(store.context.delete)
        case LocalCheckIn.syncKind: store.fetch(LocalCheckIn.self, where: #Predicate { $0.id == key }).forEach(store.context.delete)
        case LocalMealType.syncKind: store.fetch(LocalMealType.self, where: #Predicate { $0.id == key }).forEach(store.context.delete)
        default: break
        }
    }
}
