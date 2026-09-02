import AppKit

/// Broad file families, used for the treemap's base colouring.
enum FileFamily: String, CaseIterable {
    case code, media, image, archive, document, app, data, system, other

    static func of(_ item: FileItem) -> FileFamily {
        if item.isDirectory { return .other }
        switch item.ext {
        case "swift", "c", "h", "m", "mm", "cpp", "hpp", "rs", "go", "py", "rb", "js",
             "ts", "tsx", "jsx", "java", "kt", "sh", "json", "yml", "yaml", "toml", "html", "css":
            return .code
        case "mp4", "mov", "mkv", "avi", "m4v", "webm", "mp3", "wav", "aac", "flac", "m4a", "aiff":
            return .media
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "raw", "psd", "svg", "webp", "cr2", "dng":
            return .image
        case "zip", "gz", "bz2", "xz", "7z", "rar", "tar", "dmg", "pkg", "iso", "ipa", "jar":
            return .archive
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "rtf", "epub", "pages":
            return .document
        case "app", "framework", "dylib", "so", "o", "a", "bundle", "kext", "exe":
            return .app
        case "db", "sqlite", "sqlite3", "realm", "parquet", "csv", "bin", "dat", "pack":
            return .data
        case "log", "plist", "cache", "lock", "pid", "tmp":
            return .system
        default:
            return .other
        }
    }

    var color: NSColor {
        switch self {
        case .code:     return NSColor(srgbRed: 0.36, green: 0.78, blue: 0.98, alpha: 1)
        case .media:    return NSColor(srgbRed: 0.78, green: 0.44, blue: 0.98, alpha: 1)
        case .image:    return NSColor(srgbRed: 0.32, green: 0.86, blue: 0.70, alpha: 1)
        case .archive:  return NSColor(srgbRed: 0.98, green: 0.72, blue: 0.30, alpha: 1)
        case .document: return NSColor(srgbRed: 0.58, green: 0.66, blue: 0.98, alpha: 1)
        case .app:      return NSColor(srgbRed: 0.98, green: 0.45, blue: 0.55, alpha: 1)
        case .data:     return NSColor(srgbRed: 0.52, green: 0.90, blue: 0.44, alpha: 1)
        case .system:   return NSColor(srgbRed: 0.60, green: 0.62, blue: 0.70, alpha: 1)
        case .other:    return NSColor(srgbRed: 0.45, green: 0.50, blue: 0.60, alpha: 1)
        }
    }

    var label: String { rawValue.capitalized }

    /// Position in `allCases`, used to index the colour tables and the
    /// per-folder totals. Both rely on this order, so it must not change.
    var index: Int {
        switch self {
        case .code: return 0
        case .media: return 1
        case .image: return 2
        case .archive: return 3
        case .document: return 4
        case .app: return 5
        case .data: return 6
        case .system: return 7
        case .other: return 8
        }
    }
}

enum Theme {
    static let background = NSColor(srgbRed: 0.055, green: 0.063, blue: 0.086, alpha: 1)
    static let panel = NSColor(srgbRed: 0.086, green: 0.098, blue: 0.129, alpha: 1)
    static let hairline = NSColor(white: 1, alpha: 0.08)
    static let accent = NSColor(srgbRed: 1.00, green: 0.42, blue: 0.36, alpha: 1)
}
