import SwiftUI

/// Native checked menu choices on the same real Glass surface as search fields.
/// The displayed value may be a resource title and must not be translated again.
struct MacSelectionMenu<Selection: Hashable, Options: View>: View {
    let title: String
    let value: String
    @Binding var selection: Selection
    let options: Options
    let fillsWidth: Bool
    init(_ title: String, value: String, selection: Binding<Selection>, fillsWidth: Bool = false, @ViewBuilder options: () -> Options) {
        self.title = title; self.value = value; _selection = selection; self.options = options(); self.fillsWidth = fillsWidth
    }
    var body: some View {
        Menu {
            Picker(title, selection: $selection) { options }.pickerStyle(.inline)
        } label: {
            Text(verbatim: value).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton).buttonStyle(.plain)
        .frame(maxWidth: fillsWidth ? .infinity : nil)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .modifier(MacToolbarSearchSurface())
        .accessibilityLabel(title).accessibilityValue(value).help(title + ": " + value)
    }
}
