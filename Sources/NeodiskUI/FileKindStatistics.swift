//
//  FileKindStatistics.swift
//  Neodisk
//
//  Groups scanned files by kind and assigns each kind a stable display color,
//  Disk Inventory X-style: the biggest kinds get distinct palette colors, the
//  long tail shares a neutral gray.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import NeodiskKit

struct FileKind: Hashable, Identifiable, Sendable {
    let id: String
    let displayName: String
}

/// How the kind statistics group files: one row per extension, or a handful
/// of broad categories (Videos, Images, Apps, …).
enum FileKindDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case categories
    case types

    var id: String { rawValue }

    var title: String {
        switch self {
        case .categories: return "Categories"
        case .types: return "Types"
        }
    }
}

struct FileKindStat: Identifiable, Sendable {
    let kind: FileKind
    let totalAllocatedSize: Int64
    let fileCount: Int
    let rgb: SIMD3<Float>

    var id: String { kind.id }

    var color: Color {
        Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }
}

struct FileKindCatalog: Sendable {
    static let coloredKindLimit = 14

    /// Distinct saturated hues, ordered so the largest kinds get the most
    /// recognizable colors. Loosely mirrors the Disk Inventory X palette.
    nonisolated static let palette: [SIMD3<Float>] = [
        SIMD3(0.31, 0.48, 0.95), // blue
        SIMD3(0.90, 0.28, 0.26), // red
        SIMD3(0.30, 0.75, 0.32), // green
        SIMD3(0.83, 0.29, 0.83), // magenta
        SIMD3(0.95, 0.78, 0.20), // yellow
        SIMD3(0.25, 0.78, 0.82), // cyan
        SIMD3(0.95, 0.52, 0.19), // orange
        SIMD3(0.56, 0.36, 0.90), // purple
        SIMD3(0.20, 0.60, 0.50), // teal
        SIMD3(0.94, 0.45, 0.65), // pink
        SIMD3(0.62, 0.80, 0.24), // lime
        SIMD3(0.62, 0.44, 0.28), // brown
        SIMD3(0.42, 0.56, 0.14), // olive
        SIMD3(0.55, 0.27, 0.42), // plum
    ]

    nonisolated static let otherRGB = SIMD3<Float>(0.52, 0.52, 0.55)
    nonisolated static let directoryRGB = SIMD3<Float>(0.33, 0.33, 0.36)

    /// Categories keep fixed, meaningful colors regardless of size rank —
    /// videos are always blue, images always green, and so on. (Types keep
    /// rank-based colors: the biggest type gets the most prominent hue.)
    nonisolated static let categoryRGB: [String: SIMD3<Float>] = [
        "cat-video": SIMD3(0.31, 0.48, 0.95),      // blue
        "cat-image": SIMD3(0.30, 0.75, 0.32),      // green
        "cat-audio": SIMD3(0.25, 0.78, 0.82),      // cyan
        "cat-docs": SIMD3(0.95, 0.78, 0.20),       // yellow
        "cat-archive": SIMD3(0.95, 0.52, 0.19),    // orange
        "cat-code": SIMD3(0.83, 0.29, 0.83),       // magenta
        "cat-data": SIMD3(0.56, 0.36, 0.90),       // purple
        "cat-apps": SIMD3(0.90, 0.28, 0.26),       // red
        "cat-summarized": SIMD3(0.20, 0.60, 0.50), // teal
        "cat-system": SIMD3(0.62, 0.44, 0.28),     // brown
        "cat-other": otherRGB,
    ]

    static var otherColor: Color {
        Color(red: Double(otherRGB.x), green: Double(otherRGB.y), blue: Double(otherRGB.z))
    }

    let stats: [FileKindStat]
    let mode: FileKindDisplayMode
    /// Distinguishes catalog builds cheaply; every rebuild may reassign
    /// palette colors even when the kind count is unchanged.
    let buildID = UUID()
    private let rgbByKindID: [String: SIMD3<Float>]

    nonisolated init(stats: [FileKindStat], mode: FileKindDisplayMode = .types) {
        self.stats = stats
        self.mode = mode
        var mapping: [String: SIMD3<Float>] = [:]
        mapping.reserveCapacity(stats.count)
        for stat in stats {
            mapping[stat.kind.id] = stat.rgb
        }
        rgbByKindID = mapping
    }

    nonisolated static let empty = FileKindCatalog(stats: [])

    nonisolated func rgb(forKindID kindID: String) -> SIMD3<Float> {
        rgbByKindID[kindID] ?? Self.otherRGB
    }

    nonisolated func rgb(for node: FileNodeRecord) -> SIMD3<Float> {
        if node.isDirectory, !FileKindClassifier.isKindCountable(node) {
            return Self.directoryRGB
        }
        return rgb(forKindID: FileKindClassifier.kindID(for: node, mode: mode))
    }

    func color(for node: FileNodeRecord) -> Color {
        let rgb = rgb(for: node)
        return Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }

    /// Builds kind statistics for every countable node in the tree — files
    /// plus leaf-like directories (packages such as .app bundles, and
    /// auto-summarized folders) — sorted by total size, with palette colors
    /// assigned to the largest kinds.
    ///
    /// The per-node loop deals only in cheap kind-ID strings; display names
    /// (which can hit Launch Services for type descriptions) resolve once
    /// per unique kind afterwards, through a cache shared across builds.
    nonisolated static func build(
        from store: FileTreeStore,
        mode: FileKindDisplayMode = .types,
        palette: VizPalette = .standard
    ) -> FileKindCatalog {
        var sizeByKindID: [String: (size: Int64, count: Int)] = [:]

        for node in store.allNodes {
            guard FileKindClassifier.isKindCountable(node) else { continue }
            let kindID = FileKindClassifier.kindID(for: node, mode: mode)
            let existing = sizeByKindID[kindID] ?? (0, 0)
            sizeByKindID[kindID] = (existing.size + node.allocatedSize, existing.count + 1)
        }

        let ranked = sizeByKindID.sorted {
            if $0.value.size != $1.value.size {
                return $0.value.size > $1.value.size
            }
            return $0.key < $1.key
        }

        let stats = ranked.enumerated().map { index, entry in
            let rgb: SIMD3<Float>
            switch mode {
            case .categories:
                rgb = palette.categoryRGB[entry.key] ?? otherRGB
            case .types:
                rgb = index < palette.kindPalette.count ? palette.kindPalette[index] : otherRGB
            }
            return FileKindStat(
                kind: FileKindClassifier.kind(forID: entry.key, mode: mode),
                totalAllocatedSize: entry.value.size,
                fileCount: entry.value.count,
                rgb: rgb
            )
        }

        return FileKindCatalog(stats: stats, mode: mode)
    }
}

enum FileKindClassifier {
    /// Nodes that participate in kind statistics: regular files, plus
    /// leaf-like directories that behave as a single item (packages such as
    /// .app bundles, and auto-summarized folders).
    nonisolated static func isKindCountable(_ node: FileNodeRecord) -> Bool {
        !node.isDirectory || node.isPackage || node.isAutoSummarized
    }

    nonisolated static func kind(for node: FileNodeRecord, mode: FileKindDisplayMode = .types) -> FileKind {
        kind(forID: kindID(for: node, mode: mode), mode: mode)
    }

    /// A node's kind as a bare ID string — the hot-path form used per node
    /// in catalog builds and treemap coloring. Constructs no display names
    /// (type descriptions come from Launch Services and cost real time).
    nonisolated static func kindID(for node: FileNodeRecord, mode: FileKindDisplayMode) -> String {
        // Plain folders aren't part of kind statistics; describe them as
        // folders instead of falling through to "No Extension"/"Other".
        if node.isDirectory, !isKindCountable(node) {
            return "folder"
        }
        switch mode {
        case .types:
            if node.isSynthetic { return "system-data" }
            if node.isAutoSummarized { return "summarized" }
            if node.isSymbolicLink { return "symlink" }
            let ext = node.pathExtension.lowercased()
            return ext.isEmpty ? "no-extension" : ext
        case .categories:
            if node.isSynthetic { return "cat-system" }
            if node.isAutoSummarized { return "cat-summarized" }
            let ext = node.pathExtension.lowercased()
            if node.isPackage, ext == "app" || ext == "appex" {
                return "cat-apps"
            }
            if let categoryID = Self.categoryIDByExtension[ext] {
                return categoryID
            }
            // Git object stores are extensionless but often huge for
            // developers; they belong with development, not "Other".
            if isInsideGitDirectory(node.path) {
                return codeCategory.id
            }
            return "cat-other"
        }
    }

    /// Resolves a kind ID to its displayable form. Type display names are
    /// looked up in Launch Services once and cached for the process.
    nonisolated static func kind(forID id: String, mode: FileKindDisplayMode) -> FileKind {
        if id == "folder" {
            return FileKind(id: "folder", displayName: "Folder")
        }
        switch mode {
        case .types:
            switch id {
            case "system-data": return FileKind(id: id, displayName: "System Data")
            case "summarized": return FileKind(id: id, displayName: "Summarized Contents")
            case "symlink": return FileKind(id: id, displayName: "Alias")
            case "no-extension": return FileKind(id: id, displayName: "No Extension")
            default: return FileKind(id: id, displayName: displayName(forExtension: id))
            }
        case .categories:
            return categoryKindsByID[id] ?? FileKind(id: "cat-other", displayName: "Other")
        }
    }

    // MARK: - Category table

    nonisolated static let videoCategory = FileKind(id: "cat-video", displayName: "Videos")
    nonisolated static let imageCategory = FileKind(id: "cat-image", displayName: "Images")
    nonisolated static let audioCategory = FileKind(id: "cat-audio", displayName: "Audio")
    nonisolated static let documentCategory = FileKind(id: "cat-docs", displayName: "Documents")
    nonisolated static let archiveCategory = FileKind(id: "cat-archive", displayName: "Archives & Disk Images")
    nonisolated static let codeCategory = FileKind(id: "cat-code", displayName: "Code & Development")
    nonisolated static let dataCategory = FileKind(id: "cat-data", displayName: "Data & Machine Learning")
    nonisolated static let appCategory = FileKind(id: "cat-apps", displayName: "Applications")

    private nonisolated static let gitDirPattern = Array("/.git/".utf8)

    /// memmem-based search for "/.git/": this runs for every file whose
    /// extension isn't in the category table (hundreds of thousands on a
    /// dev machine), where `String.contains` was measurably slow.
    nonisolated static func isInsideGitDirectory(_ path: String) -> Bool {
        var path = path
        return path.withUTF8 { buffer in
            guard let base = buffer.baseAddress, buffer.count >= gitDirPattern.count else {
                return false
            }
            return gitDirPattern.withUnsafeBufferPointer { pattern in
                memmem(base, buffer.count, pattern.baseAddress!, pattern.count) != nil
            }
        }
    }

    /// Category ID per known extension — IDs only, so the per-node hot path
    /// never touches FileKind display names.
    nonisolated static let categoryIDByExtension: [String: String] =
        categoryByExtension.mapValues(\.id)

    nonisolated static let categoryByExtension: [String: FileKind] = {
        var table: [String: FileKind] = [:]
        func add(_ exts: [String], _ kind: FileKind) {
            for ext in exts { table[ext] = kind }
        }
        add(["mp4", "mov", "mkv", "avi", "webm", "m4v", "flv", "wmv", "mpg", "mpeg",
             "mts", "m2ts", "3gp", "vob", "ogv", "braw", "r3d",
             // macOS video libraries/packages and sidecars
             "imovielibrary", "imoviemobile", "theater", "fcpbundle", "tvlibrary",
             "srt", "vtt"], videoCategory)
        add(["jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp",
             "svg", "ico", "icns", "raw", "cr2", "cr3", "nef", "arw", "dng", "orf",
             "psd", "ai", "sketch", "xcf", "exr", "avif",
             // macOS photo libraries and editor documents
             "photoslibrary", "migratedphotolibrary", "aplibrary", "aae",
             "lrcat", "lrdata", "afphoto", "afdesign", "pxd", "procreate"], imageCategory)
        add(["mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff", "aif", "opus", "wma",
             "mid", "midi", "caf", "amr",
             // macOS audio apps: Music/GarageBand/Logic libraries, audiobooks
             "musiclibrary", "band", "logicx", "aupreset", "m4b", "m4r"], audioCategory)
        add(["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages",
             "numbers", "txt", "md", "rtf", "epub", "mobi", "odt", "ods", "odp",
             "tex", "djvu",
             // macOS document packages and mail archives
             "rtfd", "webarchive", "mbox", "emlx", "doccarchive"], documentCategory)
        add(["zip", "tar", "gz", "bz2", "xz", "zst", "7z", "rar", "dmg", "iso", "pkg",
             "xip", "tgz", "lz4", "cab", "war",
             // sparse/disk images and virtual machine disks
             "sparsebundle", "sparseimage", "cdr", "toast",
             "vmdk", "qcow2", "vdi", "pvm", "utm", "vmwarevm"], archiveCategory)
        add(["swift", "py", "js", "ts", "jsx", "tsx", "c", "cpp", "cc", "h", "hpp",
             "m", "mm", "java", "go", "rs", "rb", "php", "sh", "zsh", "bash", "pl",
             "lua", "kt", "scala", "cs", "vue", "svelte", "html", "htm", "css", "scss",
             "less", "json", "yaml", "yml", "toml", "xml", "plist", "lock", "map",
             "ipynb", "o", "a", "dylib", "so", "dll", "jar", "class", "wasm", "rlib",
             "rmeta", "pyc", "storyboard", "xib", "strings", "swiftmodule",
             "swiftdoc", "pcm", "d", "mod",
             // Xcode/developer bundles and artifacts
             "xcodeproj", "xcworkspace", "playground", "xcassets", "xcarchive",
             "framework", "dsym", "nib", "car", "kext", "bundle", "plugin",
             "qlgenerator", "prefpane", "scpt", "scptd", "workflow",
             // git packfiles
             "pack", "idx"], codeCategory)
        add(["db", "sqlite", "sqlite3", "duckdb", "parquet", "csv", "tsv", "jsonl",
             "dat", "h5", "hdf5", "npy", "npz", "pt", "pth", "pb", "tflite", "onnx",
             "pkl", "pickle", "weights", "safetensors", "ckpt", "gguf", "arrow",
             "feather", "avro", "orc", "bin",
             // Core ML and mobile databases
             "mlmodel", "mlmodelc", "mlpackage", "realm", "mdb"], dataCategory)
        add(["app", "appex", "ipa", "apk"], appCategory)
        return table
    }()

    /// SF Symbol per category, for the tinted type icons in the file lists.
    /// Keyed by category ID plus the pseudo-IDs kindID can produce
    /// ("folder"); symbols reuse the app's existing metaphors (Applications
    /// matches the sidebar, folders match the outline).
    nonisolated static func categorySymbol(forID id: String) -> String {
        switch id {
        case "cat-video": return "film.fill"
        case "cat-image": return "photo.fill"
        case "cat-audio": return "music.note"
        case "cat-docs": return "doc.text.fill"
        case "cat-archive": return "archivebox.fill"
        case "cat-code": return "chevron.left.forwardslash.chevron.right"
        case "cat-data": return "cylinder.split.1x2.fill"
        case "cat-apps": return "square.grid.2x2.fill"
        case "cat-system": return "gearshape.fill"
        case "cat-summarized", "folder": return "folder.fill"
        default: return "doc.fill"
        }
    }

    nonisolated static let categoryKindsByID: [String: FileKind] = {
        var kinds = [
            videoCategory, imageCategory, audioCategory, documentCategory,
            archiveCategory, codeCategory, dataCategory, appCategory,
            FileKind(id: "cat-system", displayName: "System Data"),
            FileKind(id: "cat-summarized", displayName: "Summarized Folders"),
            FileKind(id: "cat-other", displayName: "Other"),
        ]
        return Dictionary(uniqueKeysWithValues: kinds.map { ($0.id, $0) })
    }()

    /// Launch Services answers per extension never change within a run, and
    /// asking it per node made catalog builds take seconds.
    private nonisolated static let displayNameCache = DisplayNameCache()

    private nonisolated static func displayName(forExtension ext: String) -> String {
        displayNameCache.displayName(forExtension: ext) {
            if let type = UTType(filenameExtension: ext),
               let description = type.localizedDescription,
               !description.isEmpty {
                return "\(description) (.\(ext))"
            }
            return ".\(ext)"
        }
    }
}

private final class DisplayNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var namesByExtension: [String: String] = [:]

    func displayName(forExtension ext: String, resolve: () -> String) -> String {
        lock.lock()
        if let cached = namesByExtension[ext] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Resolve outside the lock: Launch Services lookups are slow and
        // concurrent builds (mode switch mid-build) must not serialize on
        // them. A duplicate resolve for the same extension is harmless.
        let name = resolve()
        lock.lock()
        namesByExtension[ext] = name
        lock.unlock()
        return name
    }
}
