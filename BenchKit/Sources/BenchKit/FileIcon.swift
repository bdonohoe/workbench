import Foundation

/// The symbol for a file, by its kind: code, text, data or a picture.
public enum FileIcon {
    public static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "c", "h", "m", "cpp", "java", "kt", "sh", "css", "html":
            "chevron.left.forwardslash.chevron.right"
        case "md", "txt", "rtf": "doc.plaintext"
        case "json", "yml", "yaml", "toml", "plist", "xml": "curlybraces"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tiff", "ico", "icns": "photo"
        default: "doc"
        }
    }
}
