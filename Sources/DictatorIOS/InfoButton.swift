import SwiftUI

/// A small ⓘ that shows an explanation in a popover, so Settings can
/// keep its rows short and still say what a switch actually does.
struct InfoButton: View {
    let text: String
    @State private var showing = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "info.circle")
                .imageScale(.medium)
        }
        // Borderless, so tapping it inside a List row doesn't also
        // trigger the row.
        .buttonStyle(.borderless)
        .accessibilityLabel("More info")
        .popover(isPresented: $showing) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding()
                .frame(idealWidth: 320, maxWidth: 360)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// A Settings section header with an ⓘ at the trailing edge.
struct InfoHeader: View {
    let title: String
    let info: String

    init(_ title: String, info: String) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            InfoButton(info)
                .textCase(nil)
        }
    }
}
