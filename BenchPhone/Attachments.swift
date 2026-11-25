import BenchKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// An image waiting in the compose bar to go with the next message.
struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var image: UIImage
    var data: Data

    var companion: CompanionAttachment { CompanionAttachment(name: name, data: data) }

    static func == (a: PendingAttachment, b: PendingAttachment) -> Bool { a.id == b.id }

    /// Shrinks the picture to what Claude can use (1568px on the long
    /// side) and re-encodes it as JPEG, so a 12 MB photo becomes a few
    /// hundred KB on the wire. Off the main thread: a big photo took it
    /// for a noticeable moment.
    static func make(name: String, data: Data) async -> PendingAttachment? {
        await Task.detached(priority: .userInitiated) { makeNow(name: name, data: data) }.value
    }

    nonisolated private static func makeNow(name: String, data: Data) -> PendingAttachment? {
        guard let original = UIImage(data: data) else { return nil }
        let longest = max(original.size.width, original.size.height)
        let scale = min(1, 1568 / longest)
        let size = CGSize(width: original.size.width * scale, height: original.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            original.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return nil }
        let base = (name as NSString).deletingPathExtension
        return PendingAttachment(name: (base.isEmpty ? "image" : base) + ".jpg", image: resized, data: jpeg)
    }

    static func load(_ item: PhotosPickerItem) async -> PendingAttachment? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let name = item.itemIdentifier.map { String($0.prefix(8)) } ?? "photo"
        return await make(name: name, data: data)
    }

    static func load(fileAt url: URL) async -> PendingAttachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return await make(name: url.lastPathComponent, data: data)
    }
}

/// The paperclip in the compose bar: pick from Photos or Files, then show
/// what's attached with a way to take each one off again.
struct AttachmentControls: View {
    @Binding var attachments: [PendingAttachment]
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { showsPhotos = true }
            Button("Choose File", systemImage: "folder") { showsFiles = true }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(PhoneTheme.ink)
                .frame(width: 42, height: 42)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .photosPicker(isPresented: $showsPhotos, selection: $picked, maxSelectionCount: 4, matching: .images)
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            let urls = (try? result.get()) ?? []
            Task {
                for url in urls {
                    if let attachment = await PendingAttachment.load(fileAt: url) { attachments.append(attachment) }
                }
            }
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task {
                for item in items {
                    if let attachment = await PendingAttachment.load(item) { attachments.append(attachment) }
                }
            }
        }
    }
}

struct AttachmentStrip: View {
    @Binding var attachments: [PendingAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    Image(uiImage: attachment.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.control, style: .continuous).strokeBorder(PhoneTheme.hairline))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                attachments.removeAll { $0.id == attachment.id }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(.black.opacity(0.6), in: Circle())
                                    .touchArea(horizontal: 12, vertical: 12)
                            }
                            .padding(3)
                            .accessibilityLabel("Remove \(attachment.name)")
                        }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    /// Takes images dragged onto the conversation (from Photos or Files
    /// beside it on an iPad) and attaches them to the next message. Other
    /// things being dragged are turned away.
    func imageDrop(enabled: Bool, attach: @escaping ([PendingAttachment]) -> Void) -> some View {
        modifier(ImageDrop(enabled: enabled, attach: attach))
    }
}

private struct ImageDrop: ViewModifier {
    let enabled: Bool
    let attach: ([PendingAttachment]) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: enabled ? [.image] : [], isTargeted: $targeted) { providers in
                Task { attach(await Self.load(providers)) }
                return true
            }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(PhoneTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .background(PhoneTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay {
                            Label("Drop to attach", systemImage: "photo.badge.plus")
                                .font(.headline)
                                .foregroundStyle(PhoneTheme.accent)
                        }
                        .padding(12)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: targeted)
    }

    /// Reads each dropped image, in the order they were dropped.
    private static func load(_ providers: [NSItemProvider]) async -> [PendingAttachment] {
        var found: [PendingAttachment] = []
        for provider in providers {
            guard let type = provider.registeredTypeIdentifiers
                .first(where: { UTType($0)?.conforms(to: .image) == true }) else { continue }
            let data: Data? = await withCheckedContinuation { done in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in done.resume(returning: data) }
            }
            if let data, let attachment = await PendingAttachment.make(name: provider.suggestedName ?? "image", data: data) {
                found.append(attachment)
            }
        }
        return found
    }
}
