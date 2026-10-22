import AppKit
import SwiftUI
import LibronixCore

/// AppKit owns row selection and doubleAction inside the compact NSPopover,
/// as well as accessible rows, scrolling and sortable column headers.
struct NativeStudyResourceTable: NSViewRepresentable {
    var resources: [LibraryResource]
    @Binding var selectedID: String?
    @Binding var sortOrder: [LibraryResourceSort]
    var open: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.rowHeight = 24
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (key, title, width) in [("title", "Título", 350.0), ("language", "Idioma", 110.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = L(title); column.width = width
            column.minWidth = key == "title" ? 180 : 65
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.openRow(_:))
        let menu = NSMenu()
        let item = NSMenuItem(title: L("Abrir recurso"), action: #selector(Coordinator.openRow(_:)), keyEquivalent: "")
        item.target = context.coordinator; menu.addItem(item); table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let old = coordinator.parent.resources
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        coordinator.updating = true
        defer { coordinator.updating = false }
        let order = sortOrder.first ?? LibraryResourceSort(.title)
        let descriptor = NSSortDescriptor(key: order.field == .language ? "language" : "title", ascending: order.order == .forward)
        if table.sortDescriptors != [descriptor] { table.sortDescriptors = [descriptor] }
        if old != resources || table.numberOfRows != resources.count { table.reloadData() }
        let row = resources.firstIndex { $0.id == selectedID } ?? -1
        if table.selectedRow != row {
            table.selectRowIndexes(row >= 0 ? IndexSet(integer: row) : [], byExtendingSelection: false)
        }
    }
    /// Labels expose text to accessibility while the native row owns the mouse.
    @MainActor final class RowLabel: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeStudyResourceTable
        weak var table: NSTableView?
        var updating = false
        init(_ parent: NativeStudyResourceTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.resources.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.resources.indices.contains(row) else { return nil }
            let resource = parent.resources[row]
            let text = tableColumn?.identifier.rawValue == "language" ? LibraryField.language.value(resource) : LibraryField.title.value(resource)
            let cell = NSTableCellView()
            let label = RowLabel(labelWithString: text)
            label.font = .systemFont(ofSize: NSFont.systemFontSize)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label); cell.textField = label; cell.toolTip = text
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.selectedID = parent.resources.indices.contains(table.selectedRow) ? parent.resources[table.selectedRow].id : nil
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, let descriptor = tableView.sortDescriptors.first else { return }
            parent.sortOrder = [LibraryResourceSort(descriptor.key == "language" ? .language : .title,
                order: descriptor.ascending ? .forward : .reverse)]
        }
        @objc func openRow(_ sender: Any?) {
            guard let table else { return }
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            guard parent.resources.indices.contains(row) else { return }
            parent.open(parent.resources[row].id)
        }
    }
}
