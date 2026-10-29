import SwiftUI

/// Native checked menu choices on the same real Glass surface as search fields.
/// The displayed value may be a resource title and must not be translated again.
struct MacSelectionMenu<Selection: Hashable, Options: View>: View {
    let title: String
    let value: String
    @Binding var selection: Selection
    let options: Options
    init(_ title: String, value: String, selection: Binding<Selection>, @ViewBuilder options: () -> Options) {
        self.title = title; self.value = value; _selection = selection; self.options = options()
    }
    var body: some View {
        Menu {
            Picker(title, selection: $selection) { options }.pickerStyle(.inline)
        } label: {
            Text(verbatim: value).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton).buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .modifier(MacToolbarSearchSurface())
        .accessibilityLabel(title).accessibilityValue(value).help(title + ": " + value)
    }
}
