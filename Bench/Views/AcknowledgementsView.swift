import BenchKit
import SwiftUI

/// Bench menu > Acknowledgements: the open source projects Bench ships, with
/// their licenses. Built by scripts/acknowledgements.py.
struct AcknowledgementsView: View {
    struct Entry: Decodable, Identifiable {
        let name: String
        let license: String
        let url: URL
        let text: String
        var id: String { name }
    }

    private let entries: [Entry] = {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }()

    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Workbench is free to use and is provided as is, without warranty of any kind. It's built with these open source projects. Thank you to everyone who works on them.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 14)
                ForEach(entries) { entry in
                    Divider()
                    row(entry)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 400, idealHeight: 640)
    }

    private func row(_ entry: Entry) -> some View {
        let isOpen = expanded.contains(entry.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { binding(for: entry.id).wrappedValue.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .frame(width: 12)
                        Text(entry.name).fontWeight(.medium)
                        Text(entry.license).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("\(entry.name), \(entry.license)")
                .accessibilityHint(isOpen ? "Hides the license" : "Shows the license")
                Link("Website", destination: entry.url)
                    .font(.callout)
            }
            .padding(.vertical, 9)
            if isOpen {
                Text(entry.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 20)
                    .padding(.bottom, 12)
            }
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }
}
