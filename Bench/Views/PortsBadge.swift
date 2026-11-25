import BenchKit
import SwiftUI

/// A small antenna with a count, shown when a tab or project has local
/// servers running. Hovering (or clicking) lists them.
struct PortsBadge: View {
    @Environment(PortScanner.self) private var scanner
    @Environment(AppStore.self) private var store
    let ports: [ListeningPort]
    let projectID: UUID

    @State private var showsPopover = false
    @State private var overBadge = false
    @State private var overPopover = false

    var body: some View {
        Button { showsPopover.toggle() } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.ui(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 18)
                .overlay(alignment: .topTrailing) {
                    if ports.count > 1 {
                        Text("\(ports.count)")
                            .font(.ui(size: 8, weight: .bold).monospacedDigit())
                            .foregroundStyle(.background)
                            .frame(minWidth: 11, minHeight: 11)
                            .background(Circle().fill(.secondary))
                            .offset(x: 4, y: -3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .onHover { overBadge = $0; hoverChanged() }
        .popover(isPresented: $showsPopover, arrowEdge: .trailing) {
            PortsList(ports: ports, open: { port in
                showsPopover = false
                store.openPreview(port.url, in: projectID)
            }, stopAll: {
                showsPopover = false
                scanner.stop(ports)
            })
            .onHover { overPopover = $0; hoverChanged() }
        }
        .help(ports.map { "localhost:\($0.port)" }.joined(separator: ", "))
    }

    /// Opens on hover, and closes shortly after the pointer leaves both the
    /// badge and the popover, so there's time to move between them.
    private func hoverChanged() {
        if overBadge {
            showsPopover = true
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !overBadge && !overPopover { showsPopover = false }
        }
    }
}

private struct PortsList: View {
    let ports: [ListeningPort]
    let open: (ListeningPort) -> Void
    let stopAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("PORTS")
                    .font(.ui(size: 10, weight: .semibold))
                    .kerning(0.6)
                Spacer()
                Text("\(ports.count)")
                    .font(.ui(size: 10, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)

            ForEach(ports) { port in
                PortRow(port: port) { open(port) }
            }

            Divider().padding(.vertical, 4)

            HoverRow(action: stopAll) {
                Image(systemName: "xmark")
                    .font(.ui(size: 10, weight: .semibold))
                    .frame(width: 12)
                Text(ports.count == 1 ? "Stop Server" : "Stop All Servers")
            }
        }
        .font(.ui(size: 12))
        .padding(6)
        .frame(width: 220)
    }
}

private struct PortRow: View {
    let port: ListeningPort
    let open: () -> Void

    var body: some View {
        HoverRow(action: open) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
                .frame(width: 12)
            Text(verbatim: "localhost:\(port.port)")
                .font(.ui(size: 12, design: .monospaced))
            Spacer()
            Button {
                NSWorkspace.shared.open(port.url)
            } label: {
                Image(systemName: "safari")
                    .font(.ui(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Open in your browser")
        }
        .help("Preview \(port.url.absoluteString) in Workbench")
    }
}

/// A full-width menu-style row that highlights under the pointer.
private struct HoverRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { label() }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { isHovering = $0 }
    }
}
