import SwiftUI

/// An image file's contents before and after a change. nil means the file
/// doesn't exist on that side.
struct ImagePair: Equatable {
    var old: Data?
    var new: Data?
}

/// Shows a changed image inline: before and after side by side, or just the
/// one side when the file was added or deleted.
struct ImageDiffView: View {
    let images: ImagePair

    var body: some View {
        let old = images.old.flatMap(LoadedImage.init)
        let new = images.new.flatMap(LoadedImage.init)
        Group {
            switch (old, new) {
            case let (old?, new?):
                HStack(alignment: .top, spacing: 16) {
                    ImagePane(title: "Before", image: old, tint: .red)
                    ImagePane(title: "After", image: new, tint: .green)
                }
            case let (nil, new?):
                ImagePane(title: "Added", image: new, tint: .green)
            case let (old?, nil):
                ImagePane(title: "Deleted", image: old, tint: .red)
            case (nil, nil):
                ContentUnavailableView("Can't Preview Image", systemImage: "photo",
                                       description: Text("This image couldn't be loaded."))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LoadedImage {
    let image: NSImage
    let pixelSize: CGSize
    let byteCount: Int

    init?(data: Data) {
        guard let image = NSImage(data: data) else { return nil }
        self.image = image
        let rep = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        pixelSize = rep.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
        byteCount = data.count
    }

    var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        return "\(Int(pixelSize.width)) × \(Int(pixelSize.height))  ·  \(size)"
    }
}

private struct ImagePane: View {
    let title: String
    let image: LoadedImage
    let tint: Color

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title).fontWeight(.semibold)
                Text(image.summary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)

            // Fit to the pane, but never scale small images past their own size.
            Image(nsImage: image.image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: image.image.size.width, maxHeight: image.image.size.height)
                .background(Checkerboard())
                .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.12)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The usual gray checks behind images, so transparent areas are visible.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let square: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.white.opacity(0.08)))
            for row in 0..<Int(ceil(size.height / square)) {
                for col in 0..<Int(ceil(size.width / square)) where (row + col).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(col) * square, y: CGFloat(row) * square, width: square, height: square)
                    context.fill(Path(rect), with: .color(Color.white.opacity(0.14)))
                }
            }
        }
    }
}
