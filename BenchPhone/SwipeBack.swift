import SwiftUI
import UIKit

extension View {
    /// Keeps the swipe-from-the-left-edge gesture working on a screen that
    /// hides the navigation bar. UIKit turns the gesture off whenever the
    /// bar is hidden, so a screen drawing its own header loses it.
    func keepsSwipeBack() -> some View {
        background(SwipeBackEnabler())
    }
}

private struct SwipeBackEnabler: UIViewRepresentable {
    func makeUIView(context: Context) -> SwipeBackView { SwipeBackView() }
    func updateUIView(_ view: SwipeBackView, context: Context) {}
}

private final class SwipeBackView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let navigation = next as? UINavigationController {
                SwipeBackDelegate.shared.attach(to: navigation)
                return
            }
            responder = next
        }
    }
}

/// Stands in for the navigation controller's own gesture delegate, which
/// refuses to start the pop while the bar is hidden. This one only asks
/// whether there is somewhere to go back to.
private final class SwipeBackDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = SwipeBackDelegate()
    private weak var navigation: UINavigationController?

    func attach(to navigation: UINavigationController) {
        guard let gesture = navigation.interactivePopGestureRecognizer, gesture.delegate !== self else { return }
        self.navigation = navigation
        gesture.delegate = self
        gesture.isEnabled = true
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let navigation, navigation.viewControllers.count > 1 else { return false }
        return navigation.transitionCoordinator == nil
    }
}
