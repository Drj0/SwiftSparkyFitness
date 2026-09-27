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
        store.recordHandoff(from: .local, to: .server, serverAccount: account)
        // Rows the server refused stay unlinked; keeping the offer in
        // Settings is how they get sent once whatever blocked them is fixed.
        PendingServerHandoff.isPending = !report.failures.isEmpty
        phase = .finished(report)
    }
}
