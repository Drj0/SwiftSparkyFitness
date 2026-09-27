//
//  APIError.swift
//  SwiftSparkyFitness
//

import Foundation

enum APIError: Error, LocalizedError {
    /// `status` is the HTTP status when the server answered at all. It lets
    /// the sync engine tell "that one row was refused" (4xx — skip it) from
    /// "signed out" (401 — stop) and "already gone" (404 — done).
    case server(message: String, code: String?, status: Int? = nil)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .server(let message, _, _): return message
        case .invalidResponse: return "Unexpected response from server."
        }
    }

    var status: Int? {
        if case .server(_, _, let status) = self { return status }
        return nil
    }
}

extension Error {
    /// The server couldn't be reached at all — no network, DNS, timeout,
    /// refused connection. Distinct from the server answering with an error,
    /// and the only failure that means "try again when back in range".
    var isConnectivityFailure: Bool {
        guard let urlError = self as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff,
             .dataNotAllowed, .secureConnectionFailed, .cannotLoadFromNetwork:
            return true
        default:
            return false
        }
    }

    /// Worth retrying later rather than giving up on the row: unreachable, a
    /// server error or overload (a proxy's 502 while the server restarts),
    /// a timeout, or the work being cancelled. Only a definite answer about
    /// the row itself — a 4xx other than these — is final.
    var isTransientFailure: Bool {
        if isConnectivityFailure || self is CancellationError { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        guard let status = (self as? APIError)?.status else { return false }
        return status >= 500 || status == 408 || status == 429
    }

    var isUnauthorized: Bool { (self as? APIError)?.status == 401 }
    var isNotFound: Bool { (self as? APIError)?.status == 404 }
}
