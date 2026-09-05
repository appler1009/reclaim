import Foundation

/// Broad file families, used for the treemap's base colouring.
///
/// Lives here rather than beside the Mac app's palette because the companion
/// app colours the same tiles, and two copies of this table would drift the
/// moment one side learned a new extension. The platform-specific half — how a
/// family becomes an `NSColor` or a SwiftUI `Color` — stays with each app.
public enum FileFamily: String, CaseIterable, Codable, Sendable {
    case code, media, image, archive, document, app, data, system, other

    public var label: String { rawValue.capitalized }

    /// Position in `allCases`, used to index the colour tables and the
    /// per-folder totals. Both rely on this order, so it must not change.
    public var index: Int {
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

    /// The family's colour as sRGB components, 0...1.
    ///
    /// Components rather than a colour type so that this compiles anywhere;
    /// each app wraps them in whatever its own drawing layer wants.
    public var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .code:     return (0.36, 0.78, 0.98)
        case .media:    return (0.78, 0.44, 0.98)
        case .image:    return (0.32, 0.86, 0.70)
        case .archive:  return (0.98, 0.72, 0.30)
        case .document: return (0.58, 0.66, 0.98)
        case .app:      return (0.98, 0.45, 0.55)
        case .data:     return (0.52, 0.90, 0.44)
        case .system:   return (0.60, 0.62, 0.70)
        case .other:    return (0.45, 0.50, 0.60)
        }
    }

    /// The family a filename belongs to, by extension. Directories are decided
    /// by what they hold, not by their name, so they are `.other` here.
    public static func of(extension ext: String) -> FileFamily {
        switch ext {
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
}

public enum ByteFormat {
    public static func string(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }
}
