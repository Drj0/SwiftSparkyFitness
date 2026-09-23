//
//  WaterContainer.swift
//  SwiftSparkyFitness
//
//  A vessel the user drinks from — "Bottle, 750 ml" — so a quick-add can log
//  what they actually drink instead of the backend's generic drink.
//
//  WHAT A QUICK-ADD IS WORTH
//  -------------------------
//  With no `container_id`, `POST /api/v2/measurements/water-intake` logs the
//  server's default 250 ml (`2000 / 8`). **Configuring a primary container
//  does not change that** — verified live: with a 750 ml primary set, a bare
//  `change_drinks: 1` still logged 250 ml. The server does not consult the
//  primary on its own, so the app has to pass `container_id` explicitly. That
//  is the whole reason this model exists.
//
//  Volume is stored in whatever unit the user chose and the server converts
//  on write — a 24 oz container logged 709.764 ml, i.e. 29.5735 ml/oz. The
//  same factors are mirrored here only so the app can *label* a tap before
//  making it; the number actually stored is always the server's.
//

import Foundation

struct WaterContainer: Decodable, Identifiable, Equatable {
    /// Integer, unlike most ids on this backend.
    let id: Int
    let name: String
    let volume: Double
    let unit: String
    let isPrimary: Bool
    let servingsPerContainer: Int?

    /// One serving of this container, in millilitres.
    ///
    /// Mirrors the server's own conversion so the card can say what a tap is
    /// worth before making it. An unrecognised unit falls back to treating
    /// the number as millilitres rather than guessing.
    var mlPerServing: Double {
        let factor: Double
        switch unit.lowercased() {
        case "oz": factor = 29.5735
        case "liter", "litre", "l": factor = 1000
        default: factor = 1
        }
        return volume * factor / Double(max(servingsPerContainer ?? 1, 1))
    }

    var displayVolume: String {
        let rounded = volume.rounded()
        let number = volume == rounded ? String(Int(rounded)) : String(format: "%.1f", volume)
        return "\(number) \(unit)"
    }
}

/// Creating a container. The server also accepts `hydration_factor`,
/// `is_quick_add`, `sort_order` and a set of `linked_food_*` fields that make
/// a drink also log its calories; none are modelled, because nothing in the
/// app sets them and they'd be written as defaults on every create.
struct WaterContainerInput: Encodable {
    let name: String
    let volume: Double
    let unit: String
    let servingsPerContainer: Int

    init(name: String, volume: Double, unit: String = "ml", servingsPerContainer: Int = 1) {
        self.name = name
        self.volume = volume
        self.unit = unit
        self.servingsPerContainer = servingsPerContainer
    }
}
