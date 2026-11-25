import AppKit
import BenchKit
import SwiftUI

/// Help > Send Feedback, and the toolbar's speech bubble. What's written goes
/// to Workbench's relay, which emails it to the developer, so no address
/// ships in the app. An email address left here becomes the Reply-To.
struct FeedbackView: View {
    /// Kept so closing the window by accident doesn't lose what was written.
    @AppStorage("feedbackDraft") private var message = ""
    /// Remembered for next time, since it's the same person.
    @AppStorage("feedbackEmail") private var email = ""
    @State private var isSending = false
    @State private var sent = false
    @State private var error: String?
    @State private var screenshots: [RemoteAttachment] = []
    @State private var dropTargeted = false
    @State private var pasteMonitor: Any?
    @FocusState private var messageFocused: Bool
    @FocusState private var emailFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Group {
            if sent { thanks } else { form }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Send Feedback",
                        detail: "Workbench is in beta. Tell me what's broken, confusing, or missing, or what you love. Every message is read.")

            TextEditor(text: $message)
                .font(.ui(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 160)
                .flatField(focused: messageFocused)
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("What happened, and what did you expect?")
                            .font(.ui(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .focused($messageFocused)
                .tabMovesFocus()

            screenshotRow

            VStack(alignment: .leading, spacing: 6) {
                TextField("Email (optional)", text: $email)
                    .textFieldStyle(.plain)
                    .textContentType(.emailAddress)
                    .font(.ui(size: 13))
                    .focused($emailFocused)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .flatField(focused: emailFocused)
                Text("Leave your email if you'd like a reply. Your Workbench and macOS versions are included so problems are easier to track down.")
                    .font(.ui(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error {
                Text(error)
                    .font(.ui(size: 12))
                    .foregroundStyle(Theme.Status.failed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    send()
                } label: {
                    if isSending {
                        ProgressView().controlSize(.small).padding(.horizontal, 8)
                    } else {
                        Text("Send")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.prominent)
                .disabled(trimmedMessage.isEmpty || isSending)
            }
        }
        .overlay {
            ImageDropCatcher(canDrop: !isSending, targeted: { dropTargeted = $0 }) { add(from: $0) }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: 2).padding(-8)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            messageFocused = true
            watchForPaste()
        }
        .onDisappear(perform: stopWatchingForPaste)
    }

    // MARK: Screenshots

    private var screenshotRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ForEach(screenshots) { screenshot in
                    ScreenshotThumbnail(screenshot: screenshot) {
                        screenshots.removeAll { $0.id == screenshot.id }
                    }
                }
                if screenshots.count < FeedbackScreenshot.maxCount {
                    Button("Add Screenshot…", systemImage: "paperclip", action: pickScreenshots)
                }
            }
            Text("Add up to \(FeedbackScreenshot.maxCount) by choosing, dragging, or pasting. Check they don't show anything private, like code or names.")
                .font(.ui(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pickScreenshots() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        add(panel.urls.compactMap { url in
            (try? Data(contentsOf: url)).map { RemoteAttachment(name: url.lastPathComponent, data: $0) }
        })
    }

    private func add(from pasteboard: NSPasteboard) {
        add(RemoteAttachment.pasted(from: pasteboard, numberedFrom: screenshots.count + 1))
    }

    private func add(_ new: [RemoteAttachment]) {
        let room = FeedbackScreenshot.maxCount - screenshots.count
        screenshots += new.prefix(max(room, 0))
        error = new.count > room ? "You can add up to \(FeedbackScreenshot.maxCount) screenshots." : nil
    }

    /// Command-V in this window takes a picture, and leaves text to the fields.
    private func watchForPaste() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.title == "Send Feedback",
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  !isSending else { return event }
            let pasted = RemoteAttachment.pasted(from: .general, numberedFrom: screenshots.count + 1)
            guard !pasted.isEmpty else { return event }
            add(pasted)
            return nil
        }
    }

    private func stopWatchingForPaste() {
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        pasteMonitor = nil
    }

    private var thanks: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.ui(size: 34))
                .foregroundStyle(Theme.accent)
            Text("Thanks for the feedback")
                .font(.ui(size: 15, weight: .semibold))
            Text(trimmedEmail.isEmpty
                 ? "It's on its way."
                 : "It's on its way. If there's a reply, it'll go to \(trimmedEmail).")
                .font(.ui(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Done") {
                sent = false
                dismiss()
            }
            .buttonStyle(.prominent)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func send() {
        guard !trimmedMessage.isEmpty, !isSending else { return }
        isSending = true
        error = nil
        let leftEmail = !trimmedEmail.isEmpty
        let pictures = screenshots.map(\.data)
        Task {
            do {
                try await FeedbackSender.send(message: trimmedMessage, email: trimmedEmail, screenshots: pictures)
                Analytics.capture(.feedbackSent, ["left_email": leftEmail, "screenshots": pictures.count])
                message = ""
                screenshots = []
                sent = true
            } catch {
                self.error = error.localizedDescription
            }
            isSending = false
        }
    }
}

/// A picture going with the feedback, with a button on its corner to take it off.
private struct ScreenshotThumbnail: View {
    let screenshot: RemoteAttachment
    let remove: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Group {
            if let thumbnail = screenshot.thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.ui(size: 16))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.primary, Color(nsColor: .windowBackgroundColor))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .offset(x: 7, y: -7)
            .help("Remove this screenshot")
            .accessibilityLabel("Remove \(screenshot.name)")
        }
        .help(screenshot.name)
    }
}

/// Posts feedback to the relay's /api/feedback.
enum FeedbackSender {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static let url = PushSender.relayURL.deletingLastPathComponent().appendingPathComponent("feedback")

    static func send(message: String, email: String, screenshots: [Data] = []) async throws {
        let prepared = await Task.detached(priority: .userInitiated) { screenshots.map(FeedbackScreenshot.prepare) }.value
        guard !prepared.contains(where: { $0 == nil }) else {
            throw Failure(message: "A screenshot couldn't be read or is too big. Remove it and try again. Your message is saved.")
        }
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var body: [String: Any] = [
            "message": message,
            "app": "Workbench",
            "version": version,
            "os": "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
        ]
        if !email.isEmpty { body["email"] = email }
        if !prepared.isEmpty { body["screenshots"] = prepared.compactMap { $0?.base64EncodedString() } }

        var request = URLRequest(url: url, timeoutInterval: screenshots.isEmpty ? 20 : 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure(message: "Couldn't reach the feedback service. Check your connection and try again. Your message is saved.")
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode, status != 200 else { return }
        let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
        throw Failure(message: reason ?? "The feedback couldn't be sent. Try again in a bit. Your message is saved.")
    }
}
