//
//  Exercise.swift
//  SwiftSparkyFitness
//

import Foundation

struct Exercise: Decodable, Identifiable {
    let id: String
    let name: String
    let category: String?
}
