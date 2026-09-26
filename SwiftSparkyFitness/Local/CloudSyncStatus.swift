//
//  CloudSyncStatus.swift
//  SwiftSparkyFitness
//
//  What Settings shows about iCloud sync, and where that information comes
//  from.
//
//  **SwiftData publishes no sync state of its own** — no status, no last-synced
//  date, nothing. What it does do is mirror through the same Core Data stack
//  `NSPersistentCloudKitContainer` drives, which *does* post events. So this
//  observes two things:
//
//  - `NSPersistentCloudKitContainer.eventChangedNotification` for setup,
//    import and export activity, each carrying a success flag and an error.
//    Pairing a Core Data notification with a SwiftData store is off the
//    documented path in the sense that no Apple page spells out the
//    combination, but it is the only published sync signal there is, and both
//    APIs are describing one stack.
//  - `CKAccountChanged` plus `CKContainer.accountStatus`, which is the only
//    way to tell "syncing hasn't happened yet" from "this device has no
//    iCloud account to sync to".
//
//  If the notification ever stops arriving, the state degrades to
//  `.waiting` — the honest "nothing has reported in yet" — rather than
//  claiming a sync that didn't happen. Never say "Synced" on no evidence:
//  the whole point of this screen is the user knowing whether their only
//  copy of their diary is backed up.
//

import Foundation
import Combine
import CoreData
import CloudKit

/// The iCloud account check, behind a protocol so the states below can be
/// tested without an iCloud account, a container, or a network.
protocol CloudAccountProbing: Sendable {
    func accountStatus() async -> CKAccountStatus
}

struct CloudKitAccountProbe: CloudAccountProbing {
    let containerIdentifier: String

    func accountStatus() async -> CKAccountStatus {
        do {
            return try await CKContainer(identifier: containerIdentifier).accountStatus()
        } catch {
            // An error here is itself indeterminate — it says nothing about
            // whether an account exists, only that we couldn't ask.
            return .couldNotDetermine
        }
    }
}

@MainActor
final class CloudSyncStatus: ObservableObject {
    static let shared = CloudSyncStatus()

    /// Why syncing can't happen, in the user's terms rather than CloudKit's.
    enum Unavailable: Equatable {
        /// No iCloud account on the device.
        case notSignedIn
        /// An account exists but policy (parental controls, MDM) forbids it.
        case restricted
        /// Apple's documented "ask again later" — a transient state that is
        /// specifically *not* the same as having no account, and must not be
        /// reported as one.
        case temporarilyUnavailable
        /// The check itself failed.
        case unknown
        /// The store opened without CloudKit, so nothing will ever sync in
        /// this session however healthy the account is.
        case notConfigured
    }

    enum State: Equatable {
        /// Syncing is on but nothing has reported yet this launch.
        case waiting
        /// An import or export is in flight.
        case syncing
        /// The last event succeeded. The date is the last *export* that
        /// completed — the moment this device's data reached iCloud — which
        /// is the one a user means by "is my data safe".
        case synced(Date?)
        case unavailable(Unavailable)
        case failed(String)
    }

    @Published private(set) var state: State = .waiting

    /// Persisted so the answer survives a relaunch. Without it, every cold
    /// start would show "not synced yet" on a device that is perfectly in
    /// sync, which reads as a fault.
    static let lastSyncedKey = "cloudLastSyncedAt"

    private(set) var lastSynced: Date? {
        didSet { UserDefaults.standard.set(lastSynced, forKey: Self.lastSyncedKey) }
    }

    private let probe: CloudAccountProbing
    /// Read lazily rather than captured: asking `LocalStore.shared` at init
    /// would open the SwiftData container on every launch, including server
    /// mode, where the local store is not the user's data and has no reason
    /// to exist.
    private let syncingIsConfigured: @MainActor () -> Bool
    private var observers: [NSObjectProtocol] = []

    init(
        probe: CloudAccountProbing = CloudKitAccountProbe(
            containerIdentifier: LocalStore.cloudKitContainerIdentifier
        ),
        syncingIsConfigured: @escaping @MainActor () -> Bool = { LocalStore.shared.isCloudKitEnabled },
        observingNotifications: Bool = true
    ) {
        self.probe = probe
        self.syncingIsConfigured = syncingIsConfigured
        self.lastSynced = UserDefaults.standard.object(forKey: Self.lastSyncedKey) as? Date
        if lastSynced != nil { state = .synced(lastSynced) }

        guard observingNotifications else { return }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: nil, queue: .main
            ) { [weak self] note in
                guard let event = note.userInfo?[
                    NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                ] as? NSPersistentCloudKitContainer.Event else { return }
                Task { @MainActor in self?.apply(event) }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .CKAccountChanged, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.refreshAccountStatus() }
            }
        )
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Events

    /// The three things a mirroring event can be about. Mapped off
    /// `NSPersistentCloudKitContainer.EventType` rather than used directly,
    /// because that type's `Event` has no public initialiser and so cannot
    /// be constructed in a test — the decision below is the part worth
    /// pinning, so it lives somewhere it can be.
    enum Activity: Equatable {
        case setup, importing, exporting
    }

    func apply(_ event: NSPersistentCloudKitContainer.Event) {
        let activity: Activity
        switch event.type {
        case .setup: activity = .setup
        case .import: activity = .importing
        case .export: activity = .exporting
        @unknown default: activity = .setup
        }
        apply(activity, endDate: event.endDate, error: event.error)
    }

    /// An event with no `endDate` is still running; one with an `endDate` has
    /// finished, successfully or not.
    func apply(_ activity: Activity, endDate: Date?, error: Error?) {
        guard let endDate else {
            state = .syncing
            return
        }
        if let error {
            state = .failed(Self.message(for: error))
            return
        }
        // Only an export proves *this device's* changes reached iCloud. An
        // import finishing says the other direction worked, which is good
        // news but not what "is my data backed up" asks.
        if activity == .exporting {
            lastSynced = endDate
        }
        state = .synced(lastSynced)
    }

    /// CloudKit's errors are written for developers. These are the few a user
    /// can actually act on; everything else stays generic rather than putting
    /// a raw framework string on screen.
    static func message(for error: Error) -> String {
        guard let ckError = error as? CKError else {
            return "Sync failed. It'll try again on its own."
        }
        switch ckError.code {
        case .quotaExceeded:
            return "Your iCloud storage is full, so new entries aren't being backed up."
        case .notAuthenticated:
            return "Sign in to iCloud to keep syncing."
        case .networkUnavailable, .networkFailure:
            return "No connection. Sync will resume when you're back online."
        case .managedAccountRestricted, .permissionFailure:
            return "This iCloud account isn't allowed to sync app data."
        default:
            return "Sync failed. It'll try again on its own."
        }
    }

    // MARK: - Account

    func refreshAccountStatus() async {
        guard syncingIsConfigured() else {
            state = .unavailable(.notConfigured)
            return
        }
        switch await probe.accountStatus() {
        case .available:
            // Don't overwrite a real result with an optimistic one: an
            // available account says syncing *can* happen, not that it has.
            if case .unavailable = state {
                state = lastSynced.map { State.synced($0) } ?? .waiting
            }
        case .noAccount:
            state = .unavailable(.notSignedIn)
        case .restricted:
            state = .unavailable(.restricted)
        case .temporarilyUnavailable:
            state = .unavailable(.temporarilyUnavailable)
        case .couldNotDetermine:
            state = .unavailable(.unknown)
        @unknown default:
            state = .unavailable(.unknown)
        }
    }
}

// MARK: - Presentation

extension CloudSyncStatus.State {
    /// The short line Settings shows beside "iCloud".
    var title: String {
        switch self {
        case .waiting: return "Waiting to sync"
        case .syncing: return "Syncing…"
        case .synced: return "Synced"
        case .failed: return "Sync problem"
        case .unavailable(.notSignedIn): return "Not signed in"
        case .unavailable(.restricted): return "Not allowed"
        case .unavailable(.temporarilyUnavailable): return "Unavailable right now"
        case .unavailable(.unknown): return "Can't check iCloud"
        case .unavailable(.notConfigured): return "Off"
        }
    }

    /// The sentence under it. Every unavailable case says the same thing
    /// about the data — it is still on this iPhone, and it is still the only
    /// copy — because that is the fact the user needs and the reason they
    /// might act.
    func detail(relativeTo now: Date = Date()) -> String {
        switch self {
        case .waiting:
            return "Your diary will back up to iCloud and appear on your other devices."
        case .syncing:
            return "Bringing this iPhone up to date with iCloud."
        case .synced(let date):
            guard let date else {
                return "Your diary is backed up to iCloud."
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "Last backed up \(formatter.localizedString(for: date, relativeTo: now))."
        case .failed(let message):
            return message
        case .unavailable(.notSignedIn):
            return "Sign in to iCloud to back up your diary and see it on your other devices. Until then it stays on this iPhone only."
        case .unavailable(.restricted):
            return "This account can't sync app data, so your diary stays on this iPhone only."
        case .unavailable(.temporarilyUnavailable):
            return "iCloud isn't responding. Your diary is safe on this iPhone and syncing will resume on its own."
        case .unavailable(.unknown):
            return "Couldn't reach iCloud to check. Your diary is safe on this iPhone."
        case .unavailable(.notConfigured):
            return "This build isn't set up for iCloud, so your diary stays on this iPhone only."
        }
    }

    /// Whether the diary genuinely has a second copy. Only the states that
    /// actually reached iCloud count — `.waiting` does not, because nothing
    /// has confirmed anything yet, and telling someone their only copy is
    /// safe when it might not be is the one mistake this screen must not
    /// make.
    var backsUpTheDiary: Bool {
        switch self {
        case .synced, .syncing: return true
        case .waiting, .failed, .unavailable: return false
        }
    }

    /// The consequence, in red, under the sync row — or nil when the diary
    /// genuinely has a second copy.
    ///
    /// Split out of `backsUpTheDiary` because "hasn't synced yet" and "isn't
    /// going to sync" are not the same warning, and Settings was printing the
    /// second one for both: `.waiting` showed "Nothing is backed up. Deleting
    /// the app … deletes your diary with it." directly above that state's own
    /// "Your diary will back up to iCloud and appear on your other devices."
    /// A screen that contradicts itself in two adjacent lines teaches the
    /// reader to believe neither, which costs the warning its only job.
    ///
    /// `.waiting` still warns, and that's the point of the split rather than
    /// an argument against it: nothing has confirmed a copy exists, so the
    /// line says what is true *now* without denying what is about to happen.
    var dataLossWarning: String? {
        switch self {
        case .synced, .syncing:
            return nil
        case .waiting:
            return "Until that first sync finishes, this iPhone holds the only copy of your diary."
        case .failed, .unavailable:
            return "Nothing is backed up. Deleting the app, or erasing this iPhone, deletes your diary with it."
        }
    }

    /// Whether to colour the state as something wrong rather than something
    /// in progress.
    var isProblem: Bool {
        switch self {
        case .failed: return true
        case .unavailable(.notSignedIn), .unavailable(.restricted), .unavailable(.notConfigured):
            return true
        // Transient and indeterminate states are not the user's fault and
        // not their problem to fix, so they don't get an alarm colour.
        case .unavailable(.temporarilyUnavailable), .unavailable(.unknown):
            return false
        case .waiting, .syncing, .synced: return false
        }
    }

    /// Whether to offer the button into Settings.app. Only for the states the
    /// user can actually fix there — offering it for a network blip would be
    /// sending them somewhere that can't help.
    var offersSystemSettings: Bool {
        if case .unavailable(.notSignedIn) = self { return true }
        return false
    }
}
