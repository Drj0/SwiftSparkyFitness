//
//  ServerSync.swift
//  SwiftSparkyFitness
//
//  Keeps server mode's copy of the diary in step with the server. See
//  docs/SYNC_SWITCHING_PLAN.md, step 5.
//
//  The screens only ever read and write the copy on this device, so they work
//  the same in range or out of it. This is what carries changes across:
//  push what changed here, then pull what changed there, whenever the server
//  can be reached — after an edit, on launch and returning to the app, when
//  the network comes back, and every few minutes while the app is open.
//
//  One sync at a time, strictly. A pull running while a push is mid-flight
//  could see a row the push has just created but not yet linked, and copy it
//  down a second time; queuing them removes the case entirely.
//

import Combine
import Foundation
import Network
import OSLog
import UIKit

@MainActor
final class ServerSync: ObservableObject {
    static let shared = ServerSync()

    enum Status: Equatable {
        /// Up to date as of `lastSyncedAt`, or nothing has run yet.
        case idle
        case syncing
        /// The server couldn't be reached. Everything still works on this
        /// device; changes wait here.
        case offline
        /// A definite failure other than being unreachable.
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    /// Whether the server answered the last time it was tried. Kept apart
    /// from `status`, which passes through `.syncing` on every retry: the
    /// offline banner shouldn't blink each time the app checks again.
    @Published private(set) var isReachable = true
    @Published private(set) var lastSyncedAt: Date?
    /// Changes on this device the server doesn't have yet.
    @Published private(set) var pendingCount = 0

    private(set) var account: String?
    private var user: SessionUser?
    private let server: SyncServer
    private let storeFor: (String) -> LocalStore

    /// Days re-read on a routine sync. The server has no "changed since", so
    /// edits made elsewhere are found by re-reading; older days are refreshed
    /// when the user opens them.
    static let recentDays = 14
    /// How long a day just refreshed is trusted before opening it re-reads.
    static let dayFreshness: TimeInterval = 60
    static let periodicInterval: Duration = .seconds(300)
    /// Out of range, the server is tried this often instead — a stopped
    /// server coming back changes nothing the network monitor can see.
    static let offlineRetryInterval: Duration = .seconds(60)

    private var queue: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private var periodic: Task<Void, Never>?
    private var refreshedAt: [String: Date] = [:]
    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied = true
    /// Bumped by every activate/deactivate. A sync that started under an
    /// older generation (signed out, or into another account, meanwhile)
    /// records nothing about the copy it was working on.
    private var generation = 0

    private static let logger = Logger(subsystem: "drj.SwiftSparkyFitness", category: "ServerSync")

    init(server: SyncServer = APIClient.shared, storeFor: @escaping (String) -> LocalStore = ServerCache.store(for:)) {
        self.server = server
        self.storeFor = storeFor
    }

    /// The copy the screens read. Before sign-in there is no account; an
    /// empty in-memory store stands in rather than anyone's diary.
    var store: LocalStore {
        if let account { return storeFor(account) }
        return placeholder
    }
    private lazy var placeholder = LocalStore(inMemory: true)

    var isActive: Bool { account != nil }

    // MARK: - Lifecycle

    /// Starts syncing for a signed-in user. Idempotent; a different account
    /// switches to that account's own copy.
    func activate(user: SessionUser, serverURL: String = ServerConfig.urlString) {
        let account = SyncAccount.key(serverURL: serverURL, email: user.email)
        let changed = account != self.account
        self.user = user
        self.account = account
        if changed {
            generation += 1
            refreshedAt = [:]
            lastSyncedAt = nil
            isReachable = true
            updatePending()
        }
        startMonitoring()
        schedule(after: .zero)
    }

    /// Stops syncing. `removingCopy` deletes the account's copy from this
    /// device — sign-out, once the user has accepted losing unsent changes,
    /// or after the copy has been moved into this device's own diary.
    func deactivate(removingCopy: Bool) {
        generation += 1
        scheduled?.cancel()
        periodic?.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
        if removingCopy, let account { ServerCache.remove(account: account) }
        account = nil
        user = nil
        status = .idle
        isReachable = true
        pendingCount = 0
        lastSyncedAt = nil
        refreshedAt = [:]
    }

    /// The next sync pulls the whole history again — after something wrote a
    /// lot to the server from outside this copy (sending another store's
    /// diary to it).
    func requestFullPull() {
        guard let account else { return }
        InitialPull.reset(account: account)
        schedule(after: .zero)
    }

    // MARK: - Triggers

    /// Coalesces bursts (a meal of five foods, a drink tapped three times)
    /// into one sync shortly after the last of them.
    func schedule(after delay: Duration = .seconds(1.5)) {
        guard isActive else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            await self.enqueue { await self.sync() }.value
        }
    }

    /// A local write happened.
    func localChange() {
        updatePending()
        schedule()
    }

    /// Returning to the app.
    func becameActive() {
        schedule(after: .zero)
        startPeriodic()
    }

    /// Leaving the app: an edit still in its debounce is sent now, inside
    /// the background time `sync()` asks for, not left for the next launch.
    func resignedActive() {
        periodic?.cancel()
        if pendingCount > 0 { schedule(after: .zero) }
    }

    /// Sync now and wait for it — Settings' "Sync now", leaving server mode.
    /// Returns early, leaving the sync to finish, if `timeout` passes or the
    /// caller is cancelled.
    func syncNow(timeout: Duration? = nil) async {
        guard isActive else { return }
        scheduled?.cancel()
        let task = enqueue { [weak self] in _ = await self?.sync() }
        await Self.wait(for: task, timeout: timeout)
    }

    /// Brings one day up to date before a screen reads it, waiting at most
    /// `timeout`. Past that the screen shows this device's copy, and if the
    /// refresh then changes anything the screens are told to reload.
    func refresh(day: Date, timeout: Duration = .seconds(4)) async {
        guard isActive else { return }
        // Known to be out of range: show this device's copy at once. Queuing
        // a sync per day opened would only pile up behind a server that
        // times out; the offline retries bring every recent day back anyway.
        guard isReachable else { return }
        let key = LocalDay.key(day)
        if let at = refreshedAt[key], Date().timeIntervalSince(at) < Self.dayFreshness { return }
        refreshedAt[key] = Date()

        let handoff = RefreshHandoff()
        let task = enqueue { [weak self] in
            guard let self else { return }
            let changed = await self.sync(pullDays: (day, day))
            if changed && !handoff.callerWaiting {
                NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
            }
        }
        await Self.wait(for: task, timeout: timeout)
        handoff.callerWaiting = false
    }

    /// Whether the screen that asked for a refresh is still waiting for it —
    /// if not, a change it finds has to be announced instead.
    private final class RefreshHandoff {
        var callerWaiting = true
    }

    /// Waits for `task`, but no longer than `timeout` and not past the
    /// caller's cancellation. The task itself keeps running either way:
    /// a sync is never abandoned halfway because a screen stopped waiting.
    private static func wait(for task: Task<Void, Never>, timeout: Duration?) async {
        let waiter = Waiter()
        let watcher = Task { await task.value; waiter.finish() }
        let timer = timeout.map { limit in Task { try? await Task.sleep(for: limit); waiter.finish() } }
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter.install($0) }
        } onCancel: {
            waiter.finish()
        }
        timer?.cancel()
        _ = watcher
    }

    /// Resumes one waiting caller exactly once, from whichever of "done",
    /// "timed out" or "cancelled" happens first, on whatever thread.
    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var finished = false

        func install(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func finish() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    // MARK: - The work

    /// Runs `work` after everything already queued.
    @discardableResult
    private func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        queue = task
        return task
    }

    /// Push, then pull. Returns whether the pull changed anything here.
    /// `pullDays` narrows the pull to one range (a day being opened);
    /// otherwise it's the whole history the first time, recent days after.
    @discardableResult
    private func sync(pullDays: (Date, Date)? = nil) async -> Bool {
        guard let account, let user else { return false }
        let startedIn = generation
        let store = storeFor(account)
        status = .syncing

        // A sync started as the user leaves the app gets to finish: iOS
        // suspending it between the server accepting a row and the link
        // being saved is exactly the case that costs a duplicate later.
        beginBackgroundTime()
        defer { endBackgroundTime() }

        do {
            let pushed = try await ServerPush(store: store, server: server, account: account).run()

            let today = Date()
            let range: (Date, Date)
            let isFull = pullDays == nil && !InitialPull.isDone(account: account)
            if let pullDays {
                range = pullDays
            } else if isFull {
                let start = user.createdAt ?? Calendar.current.date(byAdding: .year, value: -1, to: today) ?? today
                range = (start, today)
            } else {
                range = (Calendar.current.date(byAdding: .day, value: -Self.recentDays, to: today) ?? today, today)
            }
            let report = try await ServerPull(store: store, server: server, account: account).run(from: range.0, to: range.1)
            // Signed out, or into another account, meanwhile: this copy is
            // no longer the one in use (it may already be deleted).
            guard generation == startedIn else { return false }
            if isFull { InitialPull.markDone(account: account) }
            lastSyncedAt = Date()
            isReachable = true
            // Rows the server refused stay waiting; saying "up to date" over
            // them would hide changes that never arrive.
            if let refused = pushed.failures.first {
                let count = pushed.failures.count
                status = .failed("\(count) change\(count == 1 ? "" : "s") couldn't be sent: \(refused.message)")
            } else {
                status = .idle
            }
            updatePending()
            let changed = report.added + report.updated + report.deleted > 0
            // Whole-history and routine pulls land after the screens have
            // read; tell them. A single-day refresh tells its caller directly.
            if changed && pullDays == nil {
                NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
            }
            return changed
        } catch {
            guard generation == startedIn else { return false }
            if error.isTransientFailure || Self.isNotTheServer(error) {
                status = .offline
                isReachable = false
            } else if error.isUnauthorized {
                // APIClient has already posted .sessionExpired; sign-in
                // brings the user back to this same copy, changes intact.
                status = .idle
                isReachable = true
            } else {
                // The server answered, just not well: it's reachable, and
                // the problem is shown as one rather than as "offline".
                Self.logger.error("Sync failed: \(error.localizedDescription, privacy: .public)")
                status = .failed(error.localizedDescription)
                isReachable = true
            }
            updatePending()
            return false
        }
    }

    /// A 404 from endpoints every SparkyFitness server has, or a body that
    /// isn't JSON (a Wi-Fi login page), means something else answered in the
    /// server's place — a reverse proxy whose route went with the stopped
    /// server, say. That's out of range, not a sync problem. (A 404 about one
    /// row is handled inside the push and never reaches here.)
    static func isNotTheServer(_ error: Error) -> Bool {
        error.isNotFound || error is DecodingError
    }

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private func beginBackgroundTime() {
        endBackgroundTime()
        // Out of time, iOS kills an app still holding the task. Ending it
        // lets the app be suspended instead; the sync resumes with it, and
        // links saved so far keep a re-send from duplicating anything.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Sync diary") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTime() }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func updatePending() {
        guard let account else { pendingCount = 0; return }
        pendingCount = ServerPush(store: storeFor(account), server: server, account: account).plan().total
    }

    // MARK: - Network and timers

    private func startMonitoring() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "drj.SwiftSparkyFitness.path"))
        pathMonitor = monitor
        startPeriodic()
    }

    /// Back on a network, or onto a different one (cellular to home Wi-Fi,
    /// where a server on the LAN lives): the likeliest moments the server is
    /// reachable again.
    private func pathChanged(satisfied: Bool) {
        let cameBack = satisfied && (!lastPathSatisfied || !isReachable)
        lastPathSatisfied = satisfied
        if !satisfied, isActive {
            status = .offline
            isReachable = false
        }
        if cameBack { schedule(after: .seconds(1)) }
    }

    private func startPeriodic() {
        periodic?.cancel()
        periodic = Task { [weak self] in
            // Short ticks, deciding after each: a sleep chosen up front while
            // reachable ran the full five minutes after the server went away.
            var sinceLast: Duration = .zero
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.offlineRetryInterval)
                guard !Task.isCancelled, let self else { return }
                sinceLast += Self.offlineRetryInterval
                if !self.isReachable || sinceLast >= Self.periodicInterval {
                    sinceLast = .zero
                    self.schedule(after: .zero)
                }
            }
        }
    }
}
