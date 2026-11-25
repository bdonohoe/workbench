import AVFoundation
import SwiftUI

/// Settings > Dictation: the switch (off until you turn it on), the key,
/// the speech model's download, and the cleanup that uses Apple
/// Intelligence.
struct DictationSettings: View {
    @State private var dictation = Dictation.shared

    var body: some View {
        @Bindable var dictation = dictation
        SettingsGroup(footer: dictation.isEnabled ? nil : "If you already use a dictation app, it keeps working here as it always has, and you can leave this off.") {
            SettingsRow("Dictate messages",
                        detail: "Hold a key and talk, and what you say is typed into the chat's message box.",
                        more: "Workbench only listens while you hold the key (or after you click the microphone in the message box), and only while a chat's message box has the cursor. The speech model runs on this Mac, so nothing you say is sent anywhere.",
                        isOn: $dictation.isEnabled)
            if dictation.isEnabled {
                SettingsRow(title: "Key to hold",
                            detail: "Let go to finish. Tap Space while holding to keep talking hands-free, and press Escape to cancel.") {
                    Picker("Key to hold", selection: $dictation.key) {
                        ForEach(DictationKey.allCases) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(title: "Speech model", detail: modelDetail) {
                    modelAccessory
                }
                if dictation.microphone == .denied || dictation.microphone == .restricted {
                    SettingsRow(title: "Microphone access is off",
                                detail: "Workbench can't hear you until it's allowed to use the microphone.") {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .fixedSize()
                    }
                }
            }
        }
        .animation(Theme.Motion.layout, value: dictation.isEnabled)
        .onAppear { dictation.requestMicrophoneIfEnabled() }
        if dictation.isEnabled {
            SettingsGroup(title: "Cleanup",
                          footer: "Filler sounds like \"um\" are always left out, and spoken numbers are written as digits.") {
                SettingsRow("Fix technical terms",
                            detail: DictationCleanup.canFixTerms
                                ? "Uses Apple Intelligence on this Mac to write \"get commit\" as \"git commit\" and \"jason\" as \"JSON\"."
                                : "Needs Apple Intelligence, which isn't available on this Mac right now.",
                            more: "After the speech model, Apple's on-device language model corrects words that were clearly meant as programming terms. Its answer is only used when it kept the rest of your words as you said them. It adds a moment before the text appears.",
                            isOn: $dictation.fixesTerms)
                    .disabled(!DictationCleanup.canFixTerms)
            }
        }
    }

    private var modelDetail: String {
        switch dictation.modelState {
        case .missing: "Parakeet, about 500 MB, downloaded once."
        case .downloading: "Downloading Parakeet, about 500 MB. You can keep working."
        case .loading: "Loading Parakeet."
        case .ready, .unloaded: "Parakeet, on this Mac."
        case .failed(let message): "Couldn't get the model ready. \(message)"
        }
    }

    @ViewBuilder private var modelAccessory: some View {
        switch dictation.modelState {
        case .missing:
            Button("Download") { dictation.prepareModel() }
                .fixedSize()
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .frame(width: 110)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.ui(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Downloading")
            .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
        case .loading:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Loading")
        case .ready, .unloaded:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.ui(size: 12))
                .foregroundStyle(Theme.Status.done)
        case .failed:
            Button("Try Again") { dictation.prepareModel() }
                .fixedSize()
        }
    }
}
