//
//  APIError.swift
//  SwiftSparkyFitness
//

import Foundation

enum APIError: Error, LocalizedError {
    case server(message: String, code: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .server(let message, _): return message
        case .invalidResponse: return "Unexpected response from server."
        }
    }
}
