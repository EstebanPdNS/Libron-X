import AppKit
import LibronixCore

/// Geometry is independent of the flattened source string. The original RTF
/// importer writes \cellx into cell +8, the first signed serialized cell field.
/// Only monotonic, common right-edge grids are interpreted here. Unknown grids
/// retain automatic column layout and an explicit diagnostic.
@MainActor enum ReaderTableLayout {
    struct Cell {
        let source: LegacyTableCell
        let block: NSTextTableBlock
    }
    static func cells(_ source: LegacyTable, scale: Double, warnings: inout Set<String>) -> [Cell] {
        let edges = Set(source.rows.flatMap { $0.cells.map { Int($0.firstField) } }).sorted()
        let geometric = !edges.isEmpty && edges.count <= 256 && edges.first! > 0 &&
            source.rows.allSatisfy { row in
                let values = row.cells.map { Int($0.firstField) }
                return zip(values, values.dropFirst()).allSatisfy { $0 < $1 } && values.last == edges.last
            }
        let columns = geometric ? edges.count : max(Int(source.columnCount), source.rows.map(\.cells.count).max() ?? 1)
        guard columns > 0, columns <= 256 else { return [] }
        let table = NSTextTable()
        table.numberOfColumns = columns; table.layoutAlgorithm = geometric ? .fixedLayoutAlgorithm : .automaticLayoutAlgorithm
        table.collapsesBorders = true; table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        if !geometric { warnings.insert("Esta tabla usa columnas adaptables; sus medidas originales todavía requieren validación.") }
        var result: [Cell] = []
        for (rowIndex, row) in source.rows.enumerated() {
            var previousColumn = 0, previousEdge = 0
            for (cellIndex, cell) in row.cells.enumerated() {
                let endColumn = geometric ? (edges.firstIndex(of: Int(cell.firstField))! + 1) : cellIndex + 1
                let column = geometric ? previousColumn : cellIndex
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                            startingColumn: column, columnSpan: max(1, endColumn - column))
                block.verticalAlignment = .topAlignment
                if geometric, let total = edges.last {
                    block.setContentWidth(Double(Int(cell.firstField) - previousEdge) * 100 / Double(total), type: .percentageValueType)
                }
                // Row fields, vertical merging, cell colors and measurement
                // activation flags are preserved until their semantics are proved.
                if cell.sourceFlags != 0 || cell.secondField != 0 || cell.extendedField.map({ $0 != 0 }) == true {
                    warnings.insert("La tabla conserva propiedades de celda que aún requieren comparación con el original.")
                }
                result.append(Cell(source: cell, block: block))
                previousColumn = endColumn; previousEdge = Int(cell.firstField)
            }
        }
        return result
    }

    /// The original paragraph writer enumerates left, right, top and bottom.
    static func borderBlock(_ borders: [LegacyParagraphBorder], scale: Double) -> NSTextBlock? {
        guard borders.contains(where: { $0.width > 0 }) else { return nil }
        let block = NSTextBlock()
        let edges: [NSRectEdge] = [.minX, .maxX, .minY, .maxY]
        for (index, border) in borders.prefix(4).enumerated() where border.width > 0 {
            block.setWidth(max(0.5 * scale, Double(border.width) * scale / 20), type: .absoluteValueType,
                           for: .border, edge: edges[index])
            block.setWidth(max(0, Double(border.padding) * scale / 20), type: .absoluteValueType,
                           for: .padding, edge: edges[index])
            block.setBorderColor(ReaderTypography.color(border.color), for: edges[index])
        }
        return block
    }
}
