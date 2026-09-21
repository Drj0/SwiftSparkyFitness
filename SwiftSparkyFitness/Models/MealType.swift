//
//  MealType.swift
//  SwiftSparkyFitness
//

import Foundation

struct MealType: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let sortOrder: Int
}
