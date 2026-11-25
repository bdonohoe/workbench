import SwiftUI

public extension View {
    /// Carries out what the `/model` list asks for: switches right away,
    /// as Claude Code does in its terminal. An effort level goes in once
    /// the switch lands, since Claude Code keeps one per model.
    ///
    /// While a switch is under way, `switching` holds the model picked, so
    /// the pill can show it right away. It clears once `model` (what the
    /// session reports) matches, or after a while if it never does.
    func modelSwitching(_ request: Binding<ModelRequest?>, switching: Binding<ModelChoice?>, model: String?,
                        switchModel: @escaping (ModelChoice) -> Void,
                        setEffort: @escaping (EffortLevel) -> Void) -> some View {
        modifier(ModelSwitching(request: request, switching: switching, model: model,
                                switchModel: switchModel, setEffort: setEffort))
    }
}

public extension ModelChoice {
    /// The name a model picker shows: the model being switched to, or else
    /// the session's own.
    static func label(model: String?, switching: ModelChoice?) -> String {
        switching?.name ?? model ?? "Model"
    }

    /// Whether the model a picker shows uses limits faster.
    static func usesLimitsFaster(model: String?, switching: ModelChoice?) -> Bool {
        switching.map(\.usesLimitsFaster) ?? usesLimitsFaster(model)
    }

    /// The color for a model that uses limits faster: amber, on every
    /// theme, so it reads as a caution rather than the theme's accent.
    static let costlyColor: Color = {
        #if canImport(UIKit)
        Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.96, green: 0.72, blue: 0.24, alpha: 1)
            : UIColor(red: 0.70, green: 0.42, blue: 0.0, alpha: 1) })
        #else
        Color(NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.96, green: 0.72, blue: 0.24, alpha: 1)
            : NSColor(red: 0.70, green: 0.42, blue: 0.0, alpha: 1) })
        #endif
    }()
}

private struct ModelSwitching: ViewModifier {
    @Binding var request: ModelRequest?
    @Binding var switching: ModelChoice?
    let model: String?
    let switchModel: (ModelChoice) -> Void
    let setEffort: (EffortLevel) -> Void
    /// The effort level to set once the model switch lands.
    @State private var effortAfterSwitch: EffortLevel?

    private func go(_ choice: ModelChoice) {
        switching = choice
        switchModel(choice)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, request in
                guard let request else { return }
                self.request = nil
                guard let choice = request.model, !choice.matches(model) else {
                    if let effort = request.effort { setEffort(effort) }
                    return
                }
                effortAfterSwitch = request.effort
                go(choice)
            }
            .onChange(of: model) { _, model in
                if let switching, switching.matches(model) { self.switching = nil }
            }
            .onChange(of: switching) { old, new in
                guard old != nil, new == nil, let effort = effortAfterSwitch else { return }
                effortAfterSwitch = nil
                // A moment for Claude Code to settle on the new model.
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    setEffort(effort)
                }
            }
            // Claude confirms within a second or two. If it never does,
            // go back to showing what the session says.
            .task(id: switching) {
                guard switching != nil else { return }
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled { switching = nil }
            }
    }
}
