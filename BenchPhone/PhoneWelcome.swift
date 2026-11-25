import BenchKit
import SwiftUI

/// First launch: what Bench for iPhone (or iPad) is, what it does, then
/// pairing. Swipe or tap Continue between pages.
struct PhoneWelcome<Pair: View>: View {
    @ViewBuilder let pair: Pair
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = Self.firstPage
    @State private var glowing = false

    var body: some View {
        ZStack {
            PhoneTheme.canvas.ignoresSafeArea()
            RadialGradient(colors: [PhoneTheme.accent.opacity(glowing ? 0.26 : 0.16), .clear],
                           center: UnitPoint(x: 0.5, y: page == 0 ? 0.32 : 0.05), startRadius: 0, endRadius: 420)
                .ignoresSafeArea()
                .animation(.smooth(duration: 0.8), value: page)
                .allowsHitTesting(false)
            // On an iPhone Duo the bar down one side insets the pages, which
            // would sit off-center under the glow. Where there's room, the
            // other side gets the same inset, so they're centered on the screen.
            GeometryReader { proxy in
                let insets = proxy.safeAreaInsets
                let balance = Self.balance(leading: insets.leading, trailing: insets.trailing, width: proxy.size.width)
                ZStack {
                    TabView(selection: $page) {
                        hero.tag(0)
                        highlights.tag(1)
                        pair.tag(2)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    VStack {
                        Spacer()
                        if page < 2 {
                            footer.transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.leading, balance.leading)
                .padding(.trailing, balance.trailing)
            }
        }
        .foregroundStyle(PhoneTheme.ink)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) { glowing = true }
        }
    }

    /// What to add to each side so both are inset alike, given the safe
    /// area's insets and the width between them. Nothing when evening them
    /// out would leave the pages narrower than their column: a closed
    /// iPhone Duo has no room to spare.
    static func balance(leading: CGFloat, trailing: CGFloat, width: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        let difference = abs(leading - trailing)
        guard difference > 0, width - difference >= welcomeColumnWidth else { return (0, 0) }
        return leading < trailing ? (difference, 0) : (0, difference)
    }

    /// BENCH_WELCOME_PAGE=<n> opens on a later page, for screenshots.
    private static var firstPage: Int {
        #if DEBUG
        if let n = ProcessInfo.processInfo.environment["BENCH_WELCOME_PAGE"].flatMap(Int.init) { return n }
        #endif
        return 0
    }

    private var footer: some View {
        VStack(spacing: 18) {
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    Capsule()
                        .fill(index == page ? PhoneTheme.accent : PhoneTheme.ink.opacity(0.18))
                        .frame(width: index == page ? 22 : 7, height: 7)
                }
            }
            .animation(.snappy(duration: 0.3), value: page)
            Button {
                withAnimation(.smooth(duration: 0.4)) { page += 1 }
            } label: {
                Text(page == 0 ? "Get Started" : "Continue")
            }
            .buttonStyle(.phonePrimary)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: welcomeColumnWidth)
    }

    /// Room at the foot of a page for the dots and the button over it.
    private let footerHeight: CGFloat = 110

    private var hero: some View {
        WelcomePage {
            VStack(spacing: 0) {
                Spacer()
                BenchMark(size: 120)
                    .shadow(color: .black.opacity(0.35), radius: 26, y: 14)
                Text("Workbench for \(Device.name)")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    // Kept off the edges of a narrow screen, on one line
                    // if a slightly smaller size is all that takes.
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                Text("Your coding agent sessions, in your pocket. Keep things moving while your agent works on your Mac.")
                    .font(.body)
                    .foregroundStyle(PhoneTheme.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .padding(.top, 10)
                Spacer(minLength: footerHeight / 2)
                Spacer(minLength: footerHeight / 2)
            }
        }
    }

    private var highlights: some View {
        WelcomePage {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                Text("Everything your agent is doing")
                    .font(.title.bold())
                    .padding(.bottom, 28)
                VStack(alignment: .leading, spacing: 24) {
                    Highlight(symbol: "bubble.left.and.text.bubble.right.fill", tint: PhoneTheme.accent,
                              title: "Every session as a chat",
                              detail: "Read along, see edits and commands, and send your next message.")
                    Highlight(symbol: "hand.raised.fill", tint: PhoneTheme.waiting,
                              title: "Answer when it asks",
                              detail: "Pick an option, allow a command, or stop the agent mid-step.")
                    Highlight(symbol: "bell.badge.fill", tint: PhoneTheme.remote,
                              title: "Know when it needs you",
                              detail: "A notification and a Live Activity when your agent finishes or has a question.")
                    Highlight(symbol: "arrow.triangle.branch", tint: PhoneTheme.done,
                              title: "Changes and agents",
                              detail: "Browse diffs and start an agent on its own branch.")
                }
                Spacer(minLength: footerHeight / 2)
                Spacer(minLength: footerHeight / 2)
            }
            .padding(.horizontal, 30)
        }
    }

    private struct Highlight: View {
        let symbol: String
        let tint: Color
        let title: String
        let detail: String

        var body: some View {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: PhoneTheme.Radius.control, style: .continuous).fill(tint.opacity(0.15)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(PhoneTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// As wide as the welcome gets on an iPad, like a project's start page.
private let welcomeColumnWidth: CGFloat = 520

/// One page of the welcome, or pairing: a column that stays a comfortable
/// width on an iPad, and scrolls when large text or a small screen leaves
/// it too tall to fit. When it fits, it fills the page, so spacers inside
/// place things as they would without the scroll view.
struct WelcomePage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: welcomeColumnWidth)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// The app's icon as it is on the Home Screen, whichever one is chosen.
/// It's the real icon's picture, not a drawing of it, so it never picks
/// up the theme's colors.
struct BenchMark: View {
    var size: CGFloat = 80

    var body: some View {
        Group {
            if let url = AppIconChoice(alternateIconName: UIApplication.shared.alternateIconName).previewURL,
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
