//
//  AppMode.swift
//  SwiftSparkyFitness
//
//  Which backing store the app is running against.
//
//  The mode is chosen once (first launch, or later in Settings) and decides
//  which `APIClientProtocol` implementation every view model gets. That single
//  protocol is the seam: all 14 view models already take it by injection, and
//  the test target has implemented it in memory for eight modules, so putting
//  a local store behind it is a proven move rather than a new abstraction.
//

import Foundation

enum AppMode: String {
    /// Talks to a self-hosted SparkyFitness server.
    case server
    /// Everything on device, no network, no account.
    case local

    static let defaultsKey = "appMode"

    /// Nil until the user has chosen, which is what puts the mode picker on
    /// screen instead of the login form.
    static var current: AppMode? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
            return AppMode(rawValue: raw)
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
                return
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    static var isLocal: Bool { current == .local }
}

/// Resolves the client every view model defaults to.
///
/// Deliberately not folded into `APIClient.shared`: that name means "the
/// server client" throughout the codebase, and having it sometimes return a
/// local store would make every call site lie about what it talks to.
enum AppServices {
    static var client: APIClientProtocol {
        AppMode.isLocal ? LocalAPIClient.shared : APIClient.shared
    }
}
