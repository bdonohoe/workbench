import SwiftUI

/// A button that draws only its label, like `.plain`, and answers a press:
/// the label dims the moment the pointer goes down and comes back when it
/// lifts. A plain button whose label sets its own colors shows nothing
/// under a click, so the app's custom buttons use this instead.
///
/// `sinks` also shrinks the label a little, for buttons with a shape of
/// their own (a chip, a pill, a round icon button). Leave it off for rows
/// and text links, which would look like they were jumping.
public struct PressableButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let sinks: Bool

    public init(sinks: Bool = false) {
        self.sinks = sinks
    }

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .opacity(pressed ? Self.pressedOpacity : 1)
            .scaleEffect(pressed && sinks ? Self.pressedScale : 1)
            // Down at once, back up a little slower: the press should feel
            // like a response, and the release like a settle.
            .animation(pressed ? .easeOut(duration: 0.06) : .easeOut(duration: 0.18), value: pressed)
    }

    public static let pressedOpacity = 0.62
    public static let pressedScale = 0.96
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Plain, with a response to the press. For rows and text.
    public static var pressable: PressableButtonStyle { PressableButtonStyle() }
    /// Plain, and the label sinks a little while pressed. For chips and pills.
    public static var pressableChip: PressableButtonStyle { PressableButtonStyle(sinks: true) }
}
