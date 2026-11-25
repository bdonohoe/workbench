import SwiftUI

/// Claude's multiple-choice questions, answerable from here: pick an
/// option for each (or several, where it allows), or write your own
/// answer to a single-choice question, then send them all at once.
public struct QuestionCard: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.dockCardStyle) private var style
    public let questions: [CompanionQuestion]
    public let send: ([CompanionAnswer]) -> Void
    /// For a plan approval: the plan, to read before answering.
    public let plan: String?
    public let agentName: String
    @State private var readsPlan = false

    @State private var picked: [Int: Set<Int>] = [:]
    /// Questions answered in your own words, and the words.
    @State private var writing: Set<Int> = []
    @State private var other: [Int: String] = [:]
    /// Notes on the picked option, for questions with previews.
    @State private var notes: [Int: String] = [:]
    @State private var contentHeight: CGFloat = 0
    @State private var isSending = false

    /// Tall question sets scroll past this, with room for mock-ups.
    private var maxHeight: CGFloat {
        questions.contains(where: \.hasPreviews) ? 560 : 420
    }

    public init(questions: [CompanionQuestion], plan: String? = nil, agentName: String = "Claude", send: @escaping ([CompanionAnswer]) -> Void) {
        self.questions = questions
        self.plan = plan
        self.agentName = agentName
        self.send = send
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(palette.waiting)
                Text(questions.count == 1 ? "\(agentName) has a question" : "\(agentName) has \(questions.count) questions")
                    .font(style.title)
                    .foregroundStyle(palette.ink)
                if plan != nil {
                    Spacer(minLength: 8)
                    Button {
                        readsPlan = true
                    } label: {
                        Label("Read the Plan", systemImage: "list.bullet.clipboard")
                            .font(style.compactActions ? style.title : .subheadline.weight(.semibold))
                    }
                    .buttonStyle(.pressable)
                    .foregroundStyle(palette.accent)
                }
            }
            .sheet(isPresented: $readsPlan) {
                if let plan { PlanSheet(plan: plan, agentName: agentName) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                        questionView(question, index: index)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 1), maxHeight))
            Button {
                isSending = true
                send(answers)
            } label: {
                Text(questions.count == 1 ? "Send Answer" : "Send Answers")
                    .font(style.action.weight(.semibold))
                    // The phone's fills the card. The Mac's is the size of
                    // its Allow and Deny, at the trailing edge like them.
                    .frame(maxWidth: style.compactActions ? nil : .infinity)
            }
            .buttonStyle(CompanionProminentButtonStyle(compact: style.compactActions))
            .disabled(!isComplete || isSending)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: style.radius ?? 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: style.radius ?? 20, style: .continuous)
            .strokeBorder(palette.waiting.opacity(0.6), lineWidth: style.borderWidth ?? 1.5))
    }

    @ViewBuilder
    private func questionView(_ question: CompanionQuestion, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let header = question.header, !header.isEmpty, questions.count > 1 {
                    Text(header)
                        .font(style.caption.weight(.semibold))
                        .foregroundStyle(palette.inkMuted)
                }
                Text(question.question)
                    .font(style.heading.weight(.semibold))
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if question.multiSelect {
                    Text("Pick any that apply.")
                        .font(style.caption)
                        .foregroundStyle(palette.inkMuted)
                }
            }
            VStack(spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { option, choice in
                    row(label: choice.label, detail: choice.description, multi: question.multiSelect,
                        isOn: picked[index, default: []].contains(option) && !writing.contains(index)) {
                        toggle(option, in: index, multi: question.multiSelect)
                    }
                }
                if question.hasPreviews {
                    previewView(question, index: index)
                    if !picked[index, default: []].isEmpty {
                        textField("Notes (optional)", text: $notes, index: index)
                    }
                } else if !question.multiSelect, question.allowsOther != false {
                    // Claude Code only takes your own words cleanly for
                    // single-choice questions.
                    row(label: "Something else", detail: nil, multi: false, isOn: writing.contains(index)) {
                        writing.insert(index)
                    }
                    if writing.contains(index) {
                        textField("Your answer", text: $other, index: index)
                    }
                }
            }
        }
    }

    private func textField(_ prompt: String, text: Binding<[Int: String]>, index: Int) -> some View {
        TextField(prompt, text: Binding(get: { text.wrappedValue[index] ?? "" }, set: { text.wrappedValue[index] = $0 }), axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .font(style.heading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(palette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.hairline))
    }

    /// The mock-up Claude drew for the picked option, or the first one
    /// until you pick. Kept monospaced and unwrapped so its lines line up,
    /// scrolling sideways when it's wider than the card.
    @ViewBuilder
    private func previewView(_ question: CompanionQuestion, index: Int) -> some View {
        let shown = picked[index]?.first ?? 0
        if question.options.indices.contains(shown) {
            let option = question.options[shown]
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview: \(option.label)")
                    .font(style.caption.weight(.semibold))
                    .foregroundStyle(palette.inkMuted)
                if let preview = option.preview, !preview.isEmpty {
                    ScrollView(.horizontal) {
                        Text(preview)
                            .font(style.caption.monospaced())
                            .foregroundStyle(palette.ink)
                            .fixedSize()
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.hairline))
                } else {
                    Text("No preview for this option.")
                        .font(style.caption)
                        .foregroundStyle(palette.inkMuted)
                }
            }
            .padding(.top, 4)
            .animation(nil, value: shown)
        }
    }

    private func row(label: String, detail: String?, multi: Bool, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: multi ? (isOn ? "checkmark.square.fill" : "square") : (isOn ? "largecircle.fill.circle" : "circle"))
                    .font(style.heading)
                    .foregroundStyle(isOn ? palette.accent : palette.inkMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(style.body.weight(.medium))
                        .foregroundStyle(palette.ink)
                    if let detail, !detail.isEmpty, detail != label {
                        Text(detail)
                            .font(style.caption)
                            .foregroundStyle(palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isOn ? palette.accent.opacity(0.1) : palette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isOn ? palette.accent.opacity(0.5) : palette.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    private func toggle(_ option: Int, in index: Int, multi: Bool) {
        if multi {
            picked[index, default: []].formSymmetricDifference([option])
        } else {
            picked[index] = [option]
            writing.remove(index)
        }
    }

    private var answers: [CompanionAnswer] {
        questions.indices.map { index in
            if questions[index].hasPreviews {
                let note = notes[index]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return CompanionAnswer(selected: picked[index, default: []].sorted(), note: note.isEmpty ? nil : note)
            }
            if writing.contains(index) {
                return CompanionAnswer(selected: [], other: other[index]?.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return CompanionAnswer(selected: picked[index, default: []].sorted())
        }
    }

    private var isComplete: Bool {
        answers.allSatisfy { answer in
            if let other = answer.other { return !other.isEmpty }
            return !answer.selected.isEmpty
        }
    }
}

/// Shown while Claude Code compacts the conversation, which can take a
/// minute and otherwise looks like nothing is happening.
public struct CompactingBanner: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.dockCardStyle) private var style
    @Environment(\.motionLevel) private var motionLevel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    /// Light runs around the card while it works, on the Mac at the full
    /// Motion setting. Compacting can take a minute, too long for Calm.
    private var showsBeam: Bool {
        #if os(macOS)
        motionLevel == .full && !reduceMotion
        #else
        false
        #endif
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Claude's own mark, turning: this is Claude at work, not the
            // app waiting on something.
            ActivityMark(activity: .working, size: 13)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Compacting the conversation")
                    .font(style.title)
                    .foregroundStyle(palette.ink)
                Text("The agent is summarizing earlier messages to make room. This can take a minute, and it picks up where it left off.")
                    .font(style.caption)
                    .foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: style.radius ?? 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: style.radius ?? 16, style: .continuous)
            .strokeBorder(palette.working.opacity(showsBeam ? 0.22 : 0.5), lineWidth: style.borderWidth ?? 1.5))
        #if os(macOS)
        .overlay {
            if showsBeam {
                LayerMotion(kind: .beam(NSColor(palette.working), lineWidth: style.borderWidth ?? 1.5, count: 1, period: 5),
                            cornerRadius: style.radius ?? 16)
                    .allowsHitTesting(false)
            }
        }
        #endif
    }
}

extension CompanionSession {
    /// What it's doing, in a few words, with compacting called out.
    public var actionText: String? {
        isCompacting ? "Compacting the conversation" : action
    }
}


/// A plan to read in full before approving it.
struct PlanSheet: View {
    @Environment(\.companionPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    let plan: String
    var agentName: String = "Claude"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(agentName)'s Plan")
                    .font(.headline)
                    .foregroundStyle(palette.ink)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            ScrollView {
                MarkdownText(text: plan)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .background(palette.canvas)
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 640)
        #endif
    }
}
