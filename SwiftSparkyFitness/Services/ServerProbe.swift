//
//  ServerProbe.swift
//  SwiftSparkyFitness
//
//  Does a typed address actually lead to a SparkyFitness server?
//
//  The address field used to accept anything that parsed as a URL, so a typo
//  or a wrong port was only discovered at the *next* request — arriving as a
//  timeout on the can't-reach-the-server screen, which looks exactly like a
//  server that is simply down. The address is the one piece of configuration
//  the user has to get right before anything in the app works, so it is worth
//  answering at the point it is entered.
//

import Foundation

enum ServerProbe {
    enum Verdict: Equatable {
        case reachable
        /// Nothing answered: wrong host, server not running, or the phone is on
        /// a different network from it.
        case unreachable
        /// Something answered, but it isn't this API.
        case notSparkyFitness
    }

    /// `api/auth/get-session` is the target because it is the only endpoint
    /// that means anything *without* a session — which is the state everyone
    /// typing a server address is in. It's also already the app's cold-launch
    /// call, so a server that answers it is a server the app can use.
    static let path = "api/auth/get-session"

    /// Split from the request so the decision is testable without a server.
    ///
    /// Deliberately loose about the body. better-auth answers an
    /// unauthenticated get-session with an empty or null session rather than a
    /// user, and the precise shape wasn't confirmed against a running server
    /// when this was written — false-rejecting a real address is a worse
    /// failure than accepting a wrong one, because it blocks the only field
    /// that can fix the app. What it does insist on is that the address
    /// answers this auth question *in JSON*: a catch-all reverse proxy serving
    /// an HTML 200 for every path, or any site without this route, does not.
    static func classify(status: Int, body: Data) -> Verdict {
        // 401 is a real answer from a real auth endpoint — signed out, which is
        // precisely the state being validated — so it counts as proof of life.
        guard (200..<300).contains(status) || status == 401 else { return .notSparkyFitness }
        guard !body.isEmpty else { return .reachable }
        let isJSON = (try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])) != nil
        return isJSON ? .reachable : .notSparkyFitness
    }

    /// Ephemeral session on purpose: a probe must not drop a stranger's cookies
    /// into the jar the real client shares, and a mistyped address is a
    /// stranger. Shorter timeout than APIClient's 12s because this one is a
    /// person waiting on a button, not a screen loading.
    static func check(_ url: URL) async -> Verdict {
        var request = URLRequest(url: url.appendingPathComponent(path))
        request.timeoutInterval = 8

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .notSparkyFitness }
            return classify(status: http.statusCode, body: data)
        } catch {
            return .unreachable
        }
    }
}
