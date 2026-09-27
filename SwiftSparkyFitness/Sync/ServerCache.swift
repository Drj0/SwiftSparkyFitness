//
//  ServerCache.swift
//  SwiftSparkyFitness
//
//  Server mode's copy of the diary on this device, and the signed-in user it
//  belongs to. See docs/SYNC_SWITCHING_PLAN.md, step 5.
//
//  One store per server account, and never mirrored to iCloud:
//
//  - Per account, so signing in to a different server or account can't mix
//    two diaries or lose changes one of them hasn't sent yet — each keeps
//    its own copy, and coming back finds it as it was.
//  - Not in iCloud, because the server is what keeps devices in step here.
//    Two phones each syncing with the server *and* with each other through
//    CloudKit would see every row twice.
//

import CryptoKit
import Foundation
import OSLog

@MainActor
enum ServerCache {
    private static var stores: [String: LocalStore] = [:]
    private static let logger = Logger(subsystem: "drj.SwiftSparkyFitness", category: "ServerCache")

    /// The account's store, opened once per launch.
    static func store(for account: String) -> LocalStore {
        if let open = stores[account] { return open }
        let store: LocalStore
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try LocalStore(url: url(for: account))
        } catch {
            // Unreadable on disk: this launch works from memory and says so in
            // the log. The server still has everything that was synced.
            logger.error("Server copy couldn't open: \(error.localizedDescription, privacy: .public)")
            store = LocalStore(inMemory: true)
        }
        stores[account] = store
        return store
    }

    /// Deletes an account's copy — on sign-out, after the user has been told
    /// about anything it still held that the server doesn't.
    static func remove(account: String) {
        stores[account] = nil
        let base = url(for: account)
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: base.path + suffix))
        }
        InitialPull.reset(account: account)
    }

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "ServerCache", directoryHint: .isDirectory)
    }

    /// Hashed so an email address doesn't end up in a file name.
    static func url(for account: String) -> URL {
        let digest = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest.prefix(24)).store")
    }
}

/// Whether an account's copy has ever been filled with its whole history.
/// Until it has, each sync pulls from the account's first day; after, only
/// recent days (and any day the user opens).
enum InitialPull {
    private static func key(_ account: String) -> String { "serverCacheFullPull|\(account)" }

    static func isDone(account: String) -> Bool { UserDefaults.standard.bool(forKey: key(account)) }
    static func markDone(account: String) { UserDefaults.standard.set(true, forKey: key(account)) }
    static func reset(account: String) { UserDefaults.standard.removeObject(forKey: key(account)) }
}

/// The last user this device signed in as, per server, so server mode can
/// open straight into the diary when the server can't be reached. Not a
/// credential — the session itself lives in the cookie store — just enough
/// to show whose diary this is.
enum SessionCache {
    private static let defaultsKey = "cachedSessionUser"

    private struct Stored: Codable {
        let serverURL: String
        let email: String
        let name: String?
        let createdAt: Date?
    }

    static func save(_ user: SessionUser, serverURL: String) {
        let stored = Stored(serverURL: normalized(serverURL), email: user.email, name: user.name, createdAt: user.createdAt)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// Only for the server it was saved against: pointing the app at another
    /// address must not open the previous server's diary.
    static func user(forServer serverURL: String) -> SessionUser? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.serverURL == normalized(serverURL) else { return nil }
        return SessionUser(email: stored.email, name: stored.name, createdAt: stored.createdAt)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static func normalized(_ url: String) -> String {
        var address = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while address.hasSuffix("/") { address.removeLast() }
        return address
    }
}
