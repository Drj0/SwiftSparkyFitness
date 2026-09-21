//
//  ServerConfig.swift
//  SwiftSparkyFitness
//
//  Where the app's backend lives.
//
//  This used to be a hardcoded constant in APIClient, which was wrong twice
//  over: it published the author's machine name to anyone reading the repo,
//  and it made the address a *build-time* decision. Every SparkyFitness user
//  self-hosts, so every user's server is different — and even for one user it
//  moves. The LAN IP this started as drifted four times, and each move meant
//  editing Swift and rebuilding.
//
//  So the address is runtime configuration now: stored in UserDefaults,
//  editable in Settings, with a placeholder default so a fresh clone builds
//  and runs without anyone having to touch source.
//

import Foundation

enum ServerConfig {
    /// UserDefaults key, shared with the `@AppStorage` binding in Settings.
    static let defaultsKey = "serverURL"

    /// Deliberately not a real host — a fresh clone should fail to connect in
    /// an obvious way and be pointed at the user's own server, rather than
    /// silently trying to reach someone else's Mac.
    static let placeholder = "http://your-mac.local:3010"

    /// Resolution order: an explicit SERVER_URL in the environment (handy for
    /// dev — set it in your own scheme, which lives in gitignored xcuserdata,
    /// or pass it to `simctl launch`), then whatever Settings last saved,
    /// then the placeholder.
    static var urlString: String {
        if let env = ProcessInfo.processInfo.environment["SERVER_URL"],
           !env.trimmingCharacters(in: .whitespaces).isEmpty {
            return env
        }
        if let saved = UserDefaults.standard.string(forKey: defaultsKey),
           !saved.trimmingCharacters(in: .whitespaces).isEmpty {
            return saved
        }
        return placeholder
    }

    /// Falsely-formatted input shouldn't crash the app, so this falls back to
    /// the placeholder rather than force-unwrapping whatever was typed.
    static var url: URL {
        URL(string: urlString) ?? URL(string: placeholder)!
    }

    /// True while the app is still pointing at the shipped placeholder, so
    /// Settings can prompt instead of leaving the user to guess why every
    /// request times out.
    static var isUnconfigured: Bool { urlString == placeholder }
}
