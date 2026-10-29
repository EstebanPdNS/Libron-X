import Foundation

public enum BiblicalMeasureDimension: String, CaseIterable, Codable, Sendable {
    case length, volume, mass
}

/// Estimates are intentionally tied to a stated reference, not asserted as
/// universal historical standards. Base units are metres, litres and grams.
public enum BiblicalMeasureUnit: String, CaseIterable, Identifiable, Codable, Sendable {
    case meter, centimeter, foot, inch, cubit
    case liter, milliliter, ephah, bath, homer
    case gram, kilogram, ounce, shekel
    public var id: String { rawValue }
    public var dimension: BiblicalMeasureDimension {
        switch self {
        case .meter, .centimeter, .foot, .inch, .cubit: .length
        case .liter, .milliliter, .ephah, .bath, .homer: .volume
        case .gram, .kilogram, .ounce, .shekel: .mass
        }
    }
    public var factorToBase: Double {
        switch self {
        case .meter: 1; case .centimeter: 0.01; case .foot: 0.3048; case .inch: 0.0254; case .cubit: 0.4445
        case .liter: 1; case .milliliter: 0.001; case .ephah, .bath: 22; case .homer: 220
        case .gram: 1; case .kilogram: 1000; case .ounce: 28.349523125; case .shekel: 11.4
        }
    }
    public static func convert(_ value: Double, from: Self, to: Self) -> Double? {
        guard value.isFinite, from.dimension == to.dimension else { return nil }
        let result = value * from.factorToBase / to.factorToBase
        return result.isFinite ? result : nil
    }
}
