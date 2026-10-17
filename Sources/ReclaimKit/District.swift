import Foundation

/// What a tile is built as on the city map.
///
/// The map is drawn as a town: every tile is a city block whose area is its
/// share of the folder, and what stands on the block says what is in it. The
/// district is not just the file family renamed — it reads the name, the
/// extension, the folders above, the size, the file count and the age, so a
/// Git checkout, a pile of `node_modules` and a Photos library land in very
/// different parts of town even when they are the same family.
///
/// The garbage districts (`isGarbage`) mark things that are rebuilt on demand
/// or have plainly outlived their use: caches, dependencies, build output,
/// logs, crash dumps, used installers. Each kind gets its own kind of eyesore.
/// It is a hint, never an action: removing anything is still the user's call.
public enum District: String, CaseIterable, Codable, Sendable {
    // Garbage.
    case landfill, scrapyard, rubble, slum, toxicDump, recyclingDepot, ghostTown, logYard, junkyard
    // Code.
    case techCampus, officePark, startupGarage, aiLab, recordsHall
    // Data and services.
    case dataCenter, containerPort, embassy, postOffice, telephoneExchange, airport
    // Documents.
    case school, university, publicLibrary
    // Media.
    case stadium, concertHall, filmStudio
    // Images.
    case park, museum, artStudio
    // Archives.
    case warehouse, bankVault
    // Apps.
    case factory, industrialPark, amusementPark, workshop
    // System.
    case utilityWorks, cityHall, printShop
    // Everything else.
    case suburb, apartments, downtown

    public var label: String {
        switch self {
        case .landfill: return "Landfill"
        case .scrapyard: return "Scrapyard"
        case .rubble: return "Demolition site"
        case .slum: return "Shantytown"
        case .toxicDump: return "Toxic dump"
        case .recyclingDepot: return "Recycling depot"
        case .ghostTown: return "Ghost town"
        case .logYard: return "Log yard"
        case .junkyard: return "Junkyard"
        case .techCampus: return "Tech campus"
        case .officePark: return "Office park"
        case .startupGarage: return "Startup garage"
        case .aiLab: return "AI lab"
        case .recordsHall: return "Hall of records"
        case .dataCenter: return "Data centre"
        case .containerPort: return "Container port"
        case .embassy: return "Embassy"
        case .postOffice: return "Post office"
        case .telephoneExchange: return "Telephone exchange"
        case .airport: return "Airport"
        case .school: return "School"
        case .university: return "University"
        case .publicLibrary: return "Public library"
        case .stadium: return "Stadium"
        case .concertHall: return "Concert hall"
        case .filmStudio: return "Film studio"
        case .park: return "Park"
        case .museum: return "Museum"
        case .artStudio: return "Art studio"
        case .warehouse: return "Warehouse"
        case .bankVault: return "Bank vault"
        case .factory: return "Factory"
        case .industrialPark: return "Industrial park"
        case .amusementPark: return "Amusement park"
        case .workshop: return "Workshop"
        case .utilityWorks: return "Utility works"
        case .cityHall: return "City hall"
        case .printShop: return "Print shop"
        case .suburb: return "Suburb"
        case .apartments: return "Apartment blocks"
        case .downtown: return "Downtown"
        }
    }

    /// One line on why a block is what it is, for the context menu.
    public var hint: String {
        switch self {
        case .landfill: return "caches — whatever made them rebuilds them"
        case .scrapyard: return "downloaded dependencies — reinstalled by the package manager"
        case .rubble: return "build output — the next build makes it again"
        case .slum: return "installers and downloads that have done their job"
        case .toxicDump: return "crash reports and core dumps"
        case .recyclingDepot: return "already in the Trash"
        case .ghostTown: return "device support and archives nobody has touched in years"
        case .logYard: return "logs"
        case .junkyard: return "temporary files and leftovers"
        case .techCampus: return "a source repository"
        case .officePark: return "source code"
        case .startupGarage: return "a small code project"
        case .aiLab: return "machine-learning models"
        case .recordsHall: return "version-control history"
        case .dataCenter: return "databases and data files"
        case .containerPort: return "Docker images and containers"
        case .embassy: return "virtual machines"
        case .postOffice: return "mail"
        case .telephoneExchange: return "messages"
        case .airport: return "cloud-synced files"
        case .school: return "documents"
        case .university: return "a large collection of documents"
        case .publicLibrary: return "books and PDFs"
        case .stadium: return "a large media collection"
        case .concertHall: return "music and audio"
        case .filmStudio: return "video"
        case .park: return "images"
        case .museum: return "a photo library"
        case .artStudio: return "design and raw camera files"
        case .warehouse: return "archives"
        case .bankVault: return "backups"
        case .factory: return "applications"
        case .industrialPark: return "the Applications folder"
        case .amusementPark: return "games"
        case .workshop: return "libraries and small tools"
        case .utilityWorks: return "system files"
        case .cityHall: return "the system library"
        case .printShop: return "fonts"
        case .suburb: return "miscellaneous files"
        case .apartments: return "lots of small files"
        case .downtown: return "the desktop"
        }
    }

    public var isGarbage: Bool { archetype.isGarbage }

    /// The shape a district is built from. Several districts share one, told
    /// apart by their colours and trimmings, so the renderers stay manageable.
    public var archetype: Archetype {
        switch self {
        case .landfill, .rubble: return .mounds
        case .scrapyard, .junkyard, .recyclingDepot: return .scrap
        case .slum, .ghostTown: return .shacks
        case .toxicDump: return .toxic
        case .logYard: return .logs
        case .techCampus, .officePark, .aiLab, .telephoneExchange, .apartments, .downtown: return .towers
        case .recordsHall, .dataCenter, .embassy, .postOffice, .publicLibrary, .museum, .bankVault,
             .cityHall, .printShop: return .halls
        case .school, .university: return .campus
        case .stadium, .concertHall: return .arena
        case .park, .artStudio, .amusementPark: return .green
        case .warehouse, .containerPort, .filmStudio: return .sheds
        case .factory, .industrialPark, .workshop: return .plant
        case .utilityWorks: return .tanks
        case .suburb, .startupGarage: return .housing
        case .airport: return .airport
        }
    }

    /// How tall this district builds, relative to its archetype's usual.
    public var heightScale: Double {
        switch self {
        case .downtown: return 1.6
        case .techCampus, .telephoneExchange: return 1.3
        case .officePark, .aiLab, .university, .cityHall: return 1.0
        case .apartments: return 0.75
        case .startupGarage, .workshop: return 0.6
        case .ghostTown: return 0.7
        default: return 1.0
        }
    }
}

/// The basic shapes districts are built from.
public enum Archetype: String, CaseIterable, Sendable {
    case towers, halls, campus, arena, green, sheds, plant, tanks, housing, airport
    case mounds, scrap, shacks, toxic, logs

    public var isGarbage: Bool {
        switch self {
        case .mounds, .scrap, .shacks, .toxic, .logs: return true
        default: return false
        }
    }
}

/// Everything the classifier looks at for one tile.
public struct DistrictClue: Sendable {
    public var name: String
    public var isDirectory: Bool
    /// Lowercased extension, or "" for none.
    public var ext: String
    /// The family the tile is coloured as: its own, or what a folder mostly holds.
    public var family: FileFamily
    public var bytes: UInt64
    public var fileCount: Int
    public var modified: Date?
    /// Whether a folder has a `.git` directly inside it.
    public var hasGitFolder: Bool
    /// Names of the folders above, nearest first, as far up as the scan goes.
    public var ancestors: [String]

    public init(name: String, isDirectory: Bool, ext: String, family: FileFamily,
                bytes: UInt64 = 0, fileCount: Int = 1, modified: Date? = nil,
                hasGitFolder: Bool = false, ancestors: [String] = []) {
        self.name = name
        self.isDirectory = isDirectory
        self.ext = ext
        self.family = family
        self.bytes = bytes
        self.fileCount = fileCount
        self.modified = modified
        self.hasGitFolder = hasGitFolder
        self.ancestors = ancestors
    }
}

extension District {
    private static let mb: UInt64 = 1 << 20
    private static let gb: UInt64 = 1 << 30

    /// Folders that make everything inside them garbage of one kind. Matched
    /// against the whole lowercased name, never a substring, so a folder
    /// called "Cache Valley Photos" is somebody's photos.
    static let garbageFolders: [String: District] = [
        "caches": .landfill, "cache": .landfill, ".cache": .landfill,
        "node_modules": .scrapyard, "pods": .scrapyard, ".venv": .scrapyard, "venv": .scrapyard,
        "site-packages": .scrapyard, ".gradle": .scrapyard, ".m2": .scrapyard, ".npm": .scrapyard,
        ".yarn": .scrapyard, ".pnpm-store": .scrapyard, "carthage": .scrapyard,
        "deriveddata": .rubble, ".build": .rubble, "build": .rubble, "dist": .rubble,
        "target": .rubble, "__pycache__": .rubble, ".pytest_cache": .rubble, ".mypy_cache": .rubble,
        ".next": .rubble, ".nuxt": .rubble, ".parcel-cache": .rubble, ".turbo": .rubble,
        "cmakefiles": .rubble,
        "logs": .logYard, "log": .logYard,
        "diagnosticreports": .toxicDump, "crashreporter": .toxicDump, "cores": .toxicDump,
        "crashes": .toxicDump,
        "tmp": .junkyard, "temp": .junkyard, ".tmp": .junkyard,
        ".trash": .recyclingDepot, ".trashes": .recyclingDepot,
        "ios devicesupport": .ghostTown, "watchos devicesupport": .ghostTown,
        "tvos devicesupport": .ghostTown, "xcode previews": .ghostTown,
    ]

    static let garbageExtensions: [String: District] = [
        "log": .logYard,
        "crash": .toxicDump, "ips": .toxicDump, "core": .toxicDump, "dmp": .toxicDump,
        "tmp": .junkyard, "temp": .junkyard, "swp": .junkyard, "part": .junkyard,
        "crdownload": .junkyard,
        "dmg": .slum, "pkg": .slum, "iso": .slum, "msi": .slum, "exe": .slum,
    ]

    /// Folders and bundles known by name.
    static let landmarks: [String: District] = [
        ".git": .recordsHall, ".svn": .recordsHall, ".hg": .recordsHall,
        "applications": .industrialPark,
        "desktop": .downtown,
        "mail": .postOffice, "messages": .telephoneExchange,
        "mobile documents": .airport, "icloud drive": .airport, "dropbox": .airport,
        "google drive": .airport, "onedrive": .airport, "clouddocs": .airport,
        "cloudstorage": .airport,
        "docker": .containerPort, "com.docker.docker": .containerPort, ".docker": .containerPort,
        "orbstack": .containerPort, ".orbstack": .containerPort, "docker.raw": .containerPort,
        "parallels": .embassy, "virtual machines": .embassy, "virtual machines.localized": .embassy,
        "utm": .embassy, ".lima": .embassy, ".colima": .embassy,
        "huggingface": .aiLab, ".ollama": .aiLab, "lm studio": .aiLab, ".lmstudio": .aiLab,
        "models": .aiLab,
        "backup": .bankVault, "backups": .bankVault, "mobilesync": .bankVault,
        "steam": .amusementPark, "steamapps": .amusementPark, "games": .amusementPark,
        "epic games": .amusementPark, "openemu": .amusementPark,
        "fonts": .printShop,
        "system": .cityHall, "library": .cityHall,
        "music": .concertHall, "garageband": .concertHall, "logic": .concertHall,
        "podcasts": .concertHall, "audio music apps": .concertHall,
        "movies": .filmStudio, "videos": .filmStudio, "final cut": .filmStudio, "tv": .filmStudio,
        "pictures": .museum, "photos": .museum,
        "books": .publicLibrary, "kindle": .publicLibrary,
        "downloads": .slum,
    ]

    static let extensionLandmarks: [String: District] = [
        "vmdk": .embassy, "vdi": .embassy, "qcow2": .embassy, "utm": .embassy, "pvm": .embassy,
        "vmwarevm": .embassy, "hdd": .embassy, "vhdx": .embassy,
        "gguf": .aiLab, "safetensors": .aiLab, "ckpt": .aiLab, "pt": .aiLab, "onnx": .aiLab,
        "mlmodel": .aiLab, "mlpackage": .aiLab, "pth": .aiLab,
        "bak": .bankVault, "backup": .bankVault,
        "ttf": .printShop, "otf": .printShop, "ttc": .printShop, "woff": .printShop,
        "woff2": .printShop,
        "mp3": .concertHall, "wav": .concertHall, "flac": .concertHall, "aac": .concertHall,
        "m4a": .concertHall, "aiff": .concertHall, "logicx": .concertHall, "band": .concertHall,
        "mp4": .filmStudio, "mov": .filmStudio, "mkv": .filmStudio, "avi": .filmStudio,
        "m4v": .filmStudio, "webm": .filmStudio, "fcpbundle": .filmStudio, "prproj": .filmStudio,
        "photoslibrary": .museum,
        "psd": .artStudio, "raw": .artStudio, "dng": .artStudio, "cr2": .artStudio, "cr3": .artStudio,
        "nef": .artStudio, "arw": .artStudio, "afphoto": .artStudio, "sketch": .artStudio,
        "fig": .artStudio, "ai": .artStudio, "procreate": .artStudio,
        "epub": .publicLibrary, "mobi": .publicLibrary, "azw3": .publicLibrary,
        "ipa": .warehouse, "xcarchive": .warehouse,
        "sqlite": .dataCenter, "db": .dataCenter, "parquet": .dataCenter, "realm": .dataCenter,
        "app": .factory, "framework": .workshop, "dylib": .workshop, "bundle": .workshop,
    ]

    /// Archive-like things left alone this long are a ghost town.
    static let abandonedAfter: TimeInterval = 3 * 365 * 24 * 3600

    /// The district for one tile.
    public static func classify(_ clue: DistrictClue, now: Date = Date()) -> District {
        let name = clue.name.lowercased()

        // Garbage spreads downwards: everything inside `Caches` is landfill,
        // everything inside `node_modules` is scrap, whatever it is called.
        for ancestor in clue.ancestors {
            if let kind = garbageFolders[ancestor.lowercased()] { return kind }
        }
        if clue.isDirectory, let kind = garbageFolders[name] { return kind }
        if !clue.isDirectory {
            if name == ".ds_store" || name == "thumbs.db" { return .junkyard }
            if let kind = garbageExtensions[clue.ext] { return kind }
        }

        let inDownloads = clue.ancestors.contains { $0.lowercased() == "downloads" }
        if inDownloads, clue.family == .archive { return .slum }

        // Archives and installers nobody has opened in years.
        if let modified = clue.modified, modified > Date(timeIntervalSince1970: 86_400),
           now.timeIntervalSince(modified) > abandonedAfter,
           clue.family == .archive, clue.bytes >= 100 * mb {
            return .ghostTown
        }

        // "Library" and "System" are only the city hall near the top of a disk.
        if let landmark = landmarks[name], landmark != .cityHall || clue.ancestors.count <= 2 {
            return landmark
        }
        // Bundles are folders with an extension: `.app`, `.photoslibrary`, `.utm`.
        var ext = clue.ext
        if ext.isEmpty, let dot = name.lastIndex(of: "."), dot != name.startIndex {
            ext = String(name[name.index(after: dot)...])
        }
        if let landmark = extensionLandmarks[ext] {
            return refine(landmark, clue)
        }
        if clue.isDirectory, clue.hasGitFolder { return .techCampus }

        return zoned(clue)
    }

    /// The family's usual district, picked by how big and how busy the tile is.
    static func zoned(_ clue: DistrictClue) -> District {
        switch clue.family {
        case .code:
            if clue.bytes < 20 * mb { return .startupGarage }
            return clue.fileCount > 5000 ? .techCampus : .officePark
        case .data:
            return .dataCenter
        case .document:
            return clue.fileCount > 2000 || clue.bytes > 2 * gb ? .university : .school
        case .media:
            return clue.bytes > 5 * gb ? .stadium : (clue.isDirectory ? .concertHall : .filmStudio)
        case .image:
            return clue.fileCount > 1000 ? .museum : .park
        case .archive:
            return clue.bytes > 10 * gb ? .containerPort : .warehouse
        case .app:
            return clue.bytes < 50 * mb ? .workshop : .factory
        case .system:
            return .utilityWorks
        case .other:
            return clue.fileCount > 2000 ? .apartments : .suburb
        }
    }

    /// A few extension landmarks depend on size: a tiny app is a workshop.
    private static func refine(_ district: District, _ clue: DistrictClue) -> District {
        if district == .factory, clue.bytes < 50 * mb { return .workshop }
        return district
    }

    /// The district a family is zoned as when nothing else is known about it.
    public static func zoned(_ family: FileFamily) -> District {
        zoned(DistrictClue(name: "", isDirectory: true, ext: "", family: family,
                           bytes: 100 * mb, fileCount: 100))
    }
}
