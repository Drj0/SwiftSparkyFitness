//
//  ServerHandoff.swift
//  SwiftSparkyFitness
//
//  Moving a diary from this device (iCloud) to a server: the pre-flight,
//  the send, and the record of the move. See docs/SYNC_SWITCHING_PLAN.md,
//  "iCloud → Server".
//
//  The device's copy is never deleted. It stays as the fallback, and every
//  row sent is linked, so moving back later — or sending again after an
//  interruption — only ever sends what changed.
//

import Combine
import Foundation

/// Set when the user switches to a server from this device's diary, and
/// cleared once the diary has been sent or the user declines. The send has
/// to wait for sign-in, which happens on another screen.
enum PendingServerHandoff {
    static let defaultsKey = "pendingServerHandoff"

    static var isPending: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}

/// Server → this device's own diary. See docs/SYNC_SWITCHING_PLAN.md,
/// "Server → iCloud".
@MainActor
enum ServerToDeviceMove {
    /// Moves server mode's copy of the diary into this device's own diary.
    /// The copy is brought up to date first when the server answers — what's
    /// waiting is sent, and the whole history is fetched if this device never
    /// had it — but the move itself needs no server, so it works with the
    /// server out of range or gone. A merge: nothing only this device's diary
    /// has is touched, and rows it already has from an earlier move are
    /// matched rather than copied again. The caller switches the mode.
    static func run(user: SessionUser, serverURL: String = ServerConfig.urlString, sync: ServerSync = .shared) async throws {
        let account = SyncAccount.key(serverURL: serverURL, email: user.email)
        if sync.account != account { sync.activate(user: user, serverURL: serverURL) }
        // Cancelling ends the wait; the sync finishes in the background and
        // nothing is moved.
        await sync.syncNow()
        try Task.checkCancellation()
        try StoreTransfer.copy(from: ServerCache.store(for: account), to: .shared, account: account)
        // The server's copy holds Health's rows; this diary reads Health live
        // and mustn't carry them into iCloud (LocalAPIClient+Health).
        LocalStore.shared.removeHealthRows()
        // A copy that couldn't be brought up to date is current only to its
        // last sync; the handoff says so.
        let upToDate = sync.status == .idle && InitialPull.isDone(account: account)
        LocalStore.shared.recordHandoff(from: .server, to: .local, serverAccount: account,
                                        gapUntil: upToDate ? nil : (sync.lastSyncedAt ?? .distantPast))
        // Local mode floors day navigation on its first-use date; the copied
        // history has to be reachable.
        let start = Calendar.current.startOfDay(for: user.createdAt ?? Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date())
        let firstUse = UserDefaults.standard.object(forKey: LocalAPIClient.firstUseKey) as? Date
        if firstUse.map({ start < $0 }) ?? true {
            UserDefaults.standard.set(start, forKey: LocalAPIClient.firstUseKey)
        }
        // Everything the copy held — rows, links, unsent deletes — is now in
        // this diary. Keeping the copy too would let its unsent changes reach
        // the server a second time on a later return.
        sync.deactivate(removingCopy: true)
        NotificationCenter.default.post(name: .referenceDataChanged, object: nil)
    }
}

@MainActor
final class ServerHandoffModel: ObservableObject {
    enum Phase: Equatable {
        case checking
        case ready(ServerPush.Plan, warning: String?)
        case sending(done: Int, total: Int)
        case finished(ServerPush.Report)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .checking

    let account: String
    let serverHost: String
    private let store: LocalStore
    private let server: SyncServer
    private let isICloudDownloading: () -> Bool

    init(
        user: SessionUser,
        store: LocalStore = .shared,
        server: SyncServer = APIClient.shared,
        serverURL: String = ServerConfig.urlString,
        isICloudDownloading: (() -> Bool)? = nil
    ) {
        self.account = SyncAccount.key(serverURL: serverURL, email: user.email)
        self.serverHost = URL(string: serverURL)?.host ?? serverURL
        self.store = store
        self.server = server
        self.isICloudDownloading = isICloudDownloading ?? {
            if case .syncing = CloudSyncStatus.shared.state { return true }
            return false
        }
    }

    private var engine: ServerPush { ServerPush(store: store, server: server, account: account) }

    /// Reaches the server, then counts what would be sent. Nothing to send
    /// finishes straight away — there's nothing to ask about.
    func prepare() async {
        phase = .checking
        do {
            _ = try await server.serverVersion()
        } catch {
            phase = .failed("Couldn't reach \(serverHost). Check you're on the same network as your server, then try again.")
            return
        }
        let plan = engine.plan()
        if plan.isEmpty {
            complete(with: ServerPush.Report())
            return
        }
        // A new device can still be downloading its diary from iCloud; what
        // hasn't arrived yet can't be sent, and would look like it had been.
        let warning: String? = isICloudDownloading()
            ? "iCloud is still bringing this iPhone up to date, so some entries may not have arrived yet. You can send again later — nothing is sent twice."
            : nil
        phase = .ready(plan, warning: warning)
    }

    func send() async {
        // One run at a time: a double tap would start a second run that
        // re-reads the server before the first has created anything, and
        // exercise entries (which the server doesn't dedupe) would double.
        guard case .ready = phase else { return }
        let total = engine.plan().total
        phase = .sending(done: 0, total: total)
        do {
            let report = try await engine.run { [weak self] done in
                self?.phase = .sending(done: min(done, total), total: total)
            }
            complete(with: report)
        } catch {
            if error.isUnauthorized {
                phase = .failed("Your session expired. Sign in again and the rest will be sent — nothing already sent is sent twice.")
            } else if error.isTransientFailure {
                phase = .failed("Lost the connection to \(serverHost). What was sent is safe; try again to send the rest.")
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// "Don't send": the diary stays on this device only, and isn't offered
    /// again.
    func decline() {
        PendingServerHandoff.isPending = false
    }

    private func complete(with report: ServerPush.Report) {
        // Sending entries logged after the move isn't a new move: recording
        // one would make every other device offer "your diary moved" again.
        let latest = store.latestHandoff
        let alreadyThere = latest?.toMode == AppMode.server.rawValue && latest?.serverAccount == account
        if !alreadyThere { store.recordHandoff(from: .local, to: .server, serverAccount: account) }
        // Rows the server refused stay unlinked; keeping the offer in
        // Settings is how they get sent once whatever blocked them is fixed.
        PendingServerHandoff.isPending = !report.failures.isEmpty
        // The server now has history server mode's copy on this device may
        // have already read past; fetch it all again.
        if report.sent > 0 || report.deleted > 0 { ServerSync.shared.requestFullPull() }
        phase = .finished(report)
    }
}
