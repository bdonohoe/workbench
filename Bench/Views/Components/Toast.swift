import BenchKit
import Observation
import SwiftUI

/// A short note that something worked, like "Address Copied", shown at the
/// bottom of the main window and gone again on its own. Call
/// `Toasts.shared.show(_:symbol:)` from anywhere; one shows at a time, and
/// a new one replaces whatever is up.
@MainActor
@Observable
final class Toasts {
    static let shared = Toasts()

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        let message: String
        let symbol: String
    }

    private(set) var current: Toast?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, symbol: String = "checkmark", for duration: Duration = .seconds(1.8)) {
        let toast = Toast(message: message, symbol: symbol)
        current = toast
        AccessibilityNotification.Announcement(message).post()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, self?.current == toast else { return }
            self?.current = nil
        }
    }
}

extension View {
    /// Draws the toasts over this view. Put it once, on the window's root.
    func showsToasts() -> some View {
        overlay(alignment: .bottom) { ToastHost() }
    }
}

private struct ToastHost: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var toasts: Toasts { .shared }

    var body: some View {
        ZStack {
            if let toast = toasts.current {
                ToastView(toast: toast)
                    .id(toast.id)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 24)
        .animation(.snappy(duration: 0.25), value: toasts.current)
        .allowsHitTesting(false)
    }
}

private struct ToastView: View {
    let toast: Toasts.Toast

    var body: some View {
        Label(toast.message, systemImage: toast.symbol)
            .font(.ui(size: Theme.TypeScale.ui, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .benchGlass(in: Capsule())
            .accessibilityElement(children: .combine)
    }
}
