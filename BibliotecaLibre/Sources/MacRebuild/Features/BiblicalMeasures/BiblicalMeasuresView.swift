import SwiftUI
import LibronixCore

struct BiblicalMeasuresView: View {
    @RebuildViewState private var dimension: BiblicalMeasureDimension = .length
    @RebuildViewState private var source: BiblicalMeasureUnit = .cubit
    @RebuildViewState private var target: BiblicalMeasureUnit = .meter
    @RebuildViewState private var amount = "1"
    private var units: [BiblicalMeasureUnit] { BiblicalMeasureUnit.allCases.filter { $0.dimension == dimension } }
    private var result: Double? {
        guard let number = Double(amount.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return BiblicalMeasureUnit.convert(number, from: source, to: target)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(L("Tipo de medida"), selection: $dimension) {
                Text(L("Longitud")).tag(BiblicalMeasureDimension.length)
                Text(L("Capacidad")).tag(BiblicalMeasureDimension.volume)
                Text(L("Peso")).tag(BiblicalMeasureDimension.mass)
            }
            HStack {
                TextField(L("Cantidad"), text: $amount).macInputStyle()
                Picker(L("De"), selection: $source) { ForEach(units) { Text(L(title($0))).tag($0) } }
            }
            Picker(L("A"), selection: $target) { ForEach(units) { Text(L(title($0))).tag($0) } }
            if let result {
                Text(result.formatted(.number.precision(.significantDigits(1...8))) + " " + L(title(target)))
                    .font(.title2).textSelection(.enabled)
            } else { Text(L("Introduce una cantidad válida.")).foregroundStyle(.secondary) }
            Text(L("Las medidas antiguas son aproximadas y variaban según la época y el lugar."))
                .font(.callout).foregroundStyle(.secondary)
            Text(L("Supuestos: codo 44,45 cm; efa y bato 22 L; homer 220 L; siclo 11,4 g."))
                .font(.caption).foregroundStyle(.secondary)
            Link(L("Fuentes y contexto"), destination: URL(string: "https://www.biblegateway.com/resources/encyclopedia-of-the-bible/Weights-Measures")!)
            Link(L("Referencia de capacidad"), destination: URL(string: "https://www.biblegateway.com/passage/?search=Ezekiel+45%3A10-11&version=NRSVUE")!)
            Link(L("Referencia de peso"), destination: URL(string: "https://www.biblegateway.com/passage/?search=Ezekiel+45%3A12&version=GNT")!)
            Spacer(minLength: 0)
        }.padding(16).onChange(of: dimension) {
            switch dimension {
            case .length: source = .cubit; target = .meter
            case .volume: source = .ephah; target = .liter
            case .mass: source = .shekel; target = .gram
            }
        }
    }
    private func title(_ unit: BiblicalMeasureUnit) -> String {
        switch unit {
        case .meter: "Metros"; case .centimeter: "Centímetros"; case .foot: "Pies"; case .inch: "Pulgadas"; case .cubit: "Codos"
        case .liter: "Litros"; case .milliliter: "Mililitros"; case .ephah: "Efas"; case .bath: "Batos"; case .homer: "Hómeres"
        case .gram: "Gramos"; case .kilogram: "Kilogramos"; case .ounce: "Onzas"; case .shekel: "Siclos"
        }
    }
}
