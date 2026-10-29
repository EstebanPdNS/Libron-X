import SwiftUI
import LibronixCore

private struct WordSquare: Hashable { let row: Int; let column: Int }
struct WordSearchView: View {
    @RebuildViewState private var words = ""
    @RebuildViewState private var size = 10
    @RebuildViewState private var puzzle: WordSearchPuzzle?
    @RebuildViewState private var found: Set<String> = []
    @RebuildViewState private var start: WordSquare?
    @RebuildViewState private var error: String?
    private var marked: Set<WordSquare> {
        guard let puzzle else { return [] }
        var result: Set<WordSquare> = []
        for placement in puzzle.placements where found.contains(placement.word) {
            for index in 0..<placement.word.count {
                result.insert(.init(row: placement.row + index * placement.rowStep, column: placement.column + index * placement.columnStep))
            }
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(L("Palabras separadas por comas"), text: $words).macInputStyle()
                Button(L("Generar"), action: generate).disabled(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Stepper(L("Tamaño de cuadrícula") + ": \(size)", value: $size, in: 6...20)
            Text(LF("Usa de 1 a 30 palabras distintas de 2 a {size} letras, sin espacios.", ["size": String(size)])).font(.caption).foregroundStyle(.secondary)
            Text(L("Selecciona la primera y la última letra de cada palabra.")).font(.caption).foregroundStyle(.secondary)
            if let puzzle {
                HStack(alignment: .top, spacing: 16) {
                    ScrollView([.vertical, .horizontal]) {
                        let columns = Array(repeating: GridItem(.fixed(27), spacing: 2), count: puzzle.size)
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(0..<(puzzle.size * puzzle.size), id: \.self) { index in
                                let position = WordSquare(row: index / puzzle.size, column: index % puzzle.size)
                                Button { choose(position) } label: {
                                    Text(verbatim: puzzle.grid[position.row][position.column]).font(.system(size: 14, weight: .medium, design: .rounded))
                                        .frame(width: 27, height: 27)
                                        .background(start == position ? Color.accentColor.opacity(0.55) : marked.contains(position) ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                                }.buttonStyle(.plain)
                                    .accessibilityLabel(LF("Fila {row}, columna {column}: {letter}", ["row": String(position.row + 1), "column": String(position.column + 1), "letter": puzzle.grid[position.row][position.column]]))
                            }
                        }.padding(4)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(puzzle.placements, id: \.word) { item in
                                Label(item.word, systemImage: found.contains(item.word) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(found.contains(item.word) ? Color.accentColor : Color.primary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minWidth: 135, idealWidth: 180)
                }
                Text(LF("Palabras encontradas: {found} de {total}", ["found": String(found.count), "total": String(puzzle.placements.count)])).font(.caption)
            } else { Spacer() }
            if let error { Text(L(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(16)
    }
    private func generate() {
        let input = words.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        do { puzzle = try WordSearchGenerator.generate(words: input, size: size, seed: UInt64.random(in: .min ... .max)); found = []; start = nil; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func choose(_ square: WordSquare) {
        guard let puzzle else { return }
        guard let first = start else { start = square; error = nil; return }
        start = nil
        if let match = puzzle.placements.first(where: { !found.contains($0.word) && puzzle.matches($0, from: (first.row, first.column), to: (square.row, square.column)) }) {
            found.insert(match.word); error = nil
        } else { error = "No coincide con una palabra pendiente." }
    }
}
