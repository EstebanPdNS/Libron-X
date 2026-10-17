import Foundation

/// The public control and stored workspace value include a genuine zero endpoint.
/// At zero, the native reading surface is hidden while retaining a normal layout
/// and all navigation controls, avoiding invalid zero-point fonts or WebKit zoom.
enum ReaderZoom {
    static func isValid(_ scale: Double) -> Bool { scale.isFinite && (0...3).contains(scale) }
    static func renderingScale(_ scale: Double) -> Double { scale == 0 ? 1.5 : scale * 1.5 }
}
