//
//  FileKindClassifier.swift
//  Neodisk
//
//  Maps nodes to kind IDs and kind IDs to displayable kinds, for both
//  grouping modes. The built-in category table and Launch Services
//  display-name cache live here; the user's changes to the table are
//  FileCategoryRules', palette colors FileKindCatalog's business.
//

import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import NeodiskKit


package enum FileKindClassifier {
    /// Nodes that read as a single item rather than a container: regular
    /// files, plus directories that behave as one (packages such as .app
    /// bundles, and auto-summarized folders). This is the display-side
    /// notion used for kind naming and coloring — an expanded package still
    /// looks like one app.
    package nonisolated static func isLeafLike(_ node: FileNodeRecord) -> Bool {
        !node.isDirectory || node.isPackage || node.isAutoSummarized
    }

    /// Nodes that participate in kind/age/largest statistics: leaf-like
    /// nodes whose contents are NOT in the store — an opaque package or
    /// summarized folder counts as one item, but once "Show Package
    /// Contents" splices its children in, those are counted individually
    /// instead (counting both would double the size).
    package nonisolated static func isKindCountable(_ node: FileNodeRecord, in store: FileTreeStore) -> Bool {
        guard node.isDirectory else { return true }
        guard isLeafLike(node) else { return false }
        return !store.containsChildren(id: node.id)
    }

    package nonisolated static func kind(for node: FileNodeRecord, mode: FileKindDisplayMode = .types) -> FileKind {
        kind(forID: kindID(for: node, mode: mode), mode: mode)
    }

    /// A node's kind as a bare ID string — the hot-path form used per node
    /// in catalog builds and treemap coloring. Constructs no display names
    /// (type descriptions come from Launch Services and cost real time).
    /// Reads the installed category rules; loops over a whole tree take
    /// them once and pass them to `kindID(for:mode:rules:)`.
    package nonisolated static func kindID(for node: FileNodeRecord, mode: FileKindDisplayMode) -> String {
        kindID(for: node, mode: mode, rules: mode == .categories ? FileCategoryRules.current : .builtIn)
    }

    package nonisolated static func kindID(
        for node: FileNodeRecord,
        mode: FileKindDisplayMode,
        rules: FileCategoryRules
    ) -> String {
        // Plain folders aren't part of kind statistics; describe them as
        // folders instead of falling through to "No Extension"/"Other".
        if node.isDirectory, !isLeafLike(node) {
            return "folder"
        }
        switch mode {
        case .types:
            if node.isSynthetic { return "system-data" }
            if node.isAutoSummarized { return "summarized" }
            if node.isSymbolicLink { return "symlink" }
            if isVersionedSharedLibrary(node.name) { return "so" }
            let ext = lowercasedExtension(ofPath: node.path)
            return ext.isEmpty ? "no-extension" : ext
        case .categories:
            if node.isSynthetic { return "cat-system" }
            if node.isAutoSummarized { return "cat-summarized" }
            var path = node.path
            let categoryID = path.withUTF8 { path -> String? in
                // A folder that holds one kind of thing (a game library,
                // phone backups, a model cache) claims everything inside,
                // whatever the extensions say: a game's .png is game data.
                if let categoryID = folderRules.categoryID(inPath: path) {
                    return categoryID
                }
                let ext = lowercasedExtension(inPath: path)
                if node.isPackage, ext == "app" || ext == "appex" {
                    return appCategory.id
                }
                return rules.categoryIDByExtension[ext]
            }
            if let categoryID { return categoryID }
            if isVersionedSharedLibrary(node.name) {
                return rules.categoryIDByExtension["so"] ?? codeCategory.id
            }
            return otherCategory.id
        }
    }

    /// `NSString.pathExtension`, lowercased, read straight off the path's
    /// UTF-8: bridging to NSString per node was the bulk of a catalog
    /// build. Same rules: the last component (trailing slashes dropped),
    /// after its last dot unless that dot starts the name; Apple's version
    /// also refuses extensions with a space.
    package nonisolated static func lowercasedExtension(ofPath path: String) -> String {
        var path = path
        return path.withUTF8 { lowercasedExtension(inPath: $0) }
    }

    package nonisolated static func lowercasedExtension(inPath path: UnsafeBufferPointer<UInt8>) -> String {
        let slash: UInt8 = 0x2F, dot: UInt8 = 0x2E
        var end = path.count
        while end > 0, path[end - 1] == slash { end -= 1 }
        var index = end - 1
        while index >= 0, path[index] != dot, path[index] != slash { index -= 1 }
        // No dot in the name, or the name starts with it (".gitignore").
        guard index > 0, path[index] == dot, path[index - 1] != slash, index + 1 < end else {
            return ""
        }
        let ext = UnsafeBufferPointer(rebasing: path[(index + 1)..<end])
        var isASCII = true
        for byte in ext {
            #if canImport(Darwin)
            if byte == 0x20 { return "" }
            #endif
            if byte >= 0x80 { isASCII = false }
        }
        guard isASCII else {
            return String(decoding: ext, as: UTF8.self).lowercased()
        }
        return String(unsafeUninitializedCapacity: ext.count) { buffer in
            for (offset, byte) in ext.enumerated() {
                buffer[offset] = byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
            }
            return ext.count
        }
    }

    /// Resolves a kind ID to its displayable form. Type display names are
    /// looked up in Launch Services once and cached for the process.
    package nonisolated static func kind(forID id: String, mode: FileKindDisplayMode) -> FileKind {
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
            return categoryKindsByID[id]
                ?? FileCategoryRules.current.customKindsByID[id]
                ?? otherCategory
        }
    }

    // MARK: - Category table

    package nonisolated static let videoCategory = FileKind(id: "cat-video", displayName: "Videos")
    package nonisolated static let imageCategory = FileKind(id: "cat-image", displayName: "Images")
    package nonisolated static let audioCategory = FileKind(id: "cat-audio", displayName: "Audio")
    package nonisolated static let documentCategory = FileKind(id: "cat-docs", displayName: "Documents")
    package nonisolated static let archiveCategory = FileKind(id: "cat-archive", displayName: "Archives & Disk Images")
    package nonisolated static let codeCategory = FileKind(id: "cat-code", displayName: "Code & Development")
    package nonisolated static let dataCategory = FileKind(id: "cat-data", displayName: "Data & Machine Learning")
    package nonisolated static let appCategory = FileKind(id: "cat-apps", displayName: "Applications")
    package nonisolated static let modelCategory = FileKind(id: "cat-3d", displayName: "3D & CAD")
    package nonisolated static let gameCategory = FileKind(id: "cat-games", displayName: "Games")
    package nonisolated static let backupCategory = FileKind(id: "cat-backups", displayName: "Backups")
    package nonisolated static let otherCategory = FileKind(id: "cat-other", displayName: "Other")

    /// The categories an extension can be put in, in menu order: the
    /// built-in ones (Other last), before any the user made.
    package nonisolated static let assignableCategories: [FileKind] = [
        videoCategory, imageCategory, audioCategory, documentCategory, archiveCategory,
        backupCategory, codeCategory, dataCategory, modelCategory, gameCategory,
        appCategory, otherCategory,
    ]

    /// "libc.so.6", "libfoo.so.1.2.3": ELF shared libraries carry their
    /// version after ".so", so the extension is a number — they belong
    /// with the .so/.dylib files, not in Other.
    nonisolated static func isVersionedSharedLibrary(_ name: String) -> Bool {
        guard let range = name.range(of: ".so.", options: .backwards) else { return false }
        let version = name[range.upperBound...]
        return !version.isEmpty && version.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
    }

    /// Folders whose contents all belong to one category. Mostly stores
    /// with no extensions to go by — Git objects, phone backups, model
    /// caches named by hash — or with every extension under the sun
    /// (game installs). A pattern matches as whole path components.
    package nonisolated static let folderRules = FolderCategoryRules([
        ("/.git/", codeCategory.id),
        ("/steamapps/", gameCategory.id),
        ("/Epic Games/", gameCategory.id),
        ("/GOG Games/", gameCategory.id),
        ("/Riot Games/", gameCategory.id),
        ("/MobileSync/Backup/", backupCategory.id),
        ("/Backups.backupdb/", backupCategory.id),
        ("/timeshift/snapshots/", backupCategory.id),
        ("/.cache/huggingface/", dataCategory.id),
        ("/.ollama/models/", dataCategory.id),
        ("/.lmstudio/models/", dataCategory.id),
    ])

    /// Built-in category per known extension, as IDs — the per-node hot
    /// path never touches FileKind display names.
    package nonisolated static let builtInCategoryIDByExtension: [String: String] = {
        var table: [String: String] = [:]
        func add(_ exts: [String], _ kind: FileKind) {
            for ext in exts { table[ext] = kind.id }
        }
        add(["mp4", "mov", "mkv", "avi", "webm", "m4v", "flv", "wmv", "mpg", "mpeg",
             "mts", "m2ts", "3gp", "vob", "ogv", "braw", "r3d", "mxf", "dv", "rmvb",
             "insv", "lrv", "aaf",
             // editor projects, render caches and macOS video libraries
             "prproj", "aep", "drp", "cfa", "pek", "motn",
             "imovielibrary", "imoviemobile", "theater", "fcpbundle", "tvlibrary",
             "srt", "vtt"], videoCategory)
        add(["jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp",
             "svg", "ico", "icns", "cr2", "cr3", "nef", "arw", "dng", "orf", "raf",
             "rw2", "pef", "srw", "x3f", "3fr", "iiq", "jxl", "jp2", "tga", "hdr", "dds",
             "psd", "psb", "ai", "sketch", "xcf", "exr", "avif", "kra", "fig", "xd", "clip",
             // macOS photo libraries and editor documents
             "photoslibrary", "migratedphotolibrary", "aplibrary", "aae",
             "lrcat", "lrdata", "afphoto", "afdesign", "pxd", "procreate"], imageCategory)
        add(["mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff", "aif", "opus", "wma",
             "mid", "midi", "caf", "amr", "ape", "wv", "dsf", "dff", "aax",
             // music apps: projects, libraries, sample instruments, audiobooks
             "musiclibrary", "band", "logicx", "aupreset", "m4b", "m4r",
             "als", "alp", "flp", "ptx", "rpp", "cpr", "song", "aup3",
             "sf2", "sfz", "nki", "nkx", "nkm", "ncw", "exs"], audioCategory)
        add(["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages",
             "numbers", "txt", "md", "rtf", "epub", "mobi", "odt", "ods", "odp",
             "tex", "djvu", "azw", "azw3", "kfx", "cbz", "cbr", "fb2", "xps", "chm",
             "ps", "eps", "indd", "afpub", "one", "vcf", "ics",
             // mail archives (Outlook's can be tens of gigabytes) and fonts
             "pst", "ost", "eml", "msg",
             "ttf", "otf", "ttc", "woff", "woff2", "dfont",
             // macOS document packages and mail archives
             "rtfd", "webarchive", "mbox", "emlx", "doccarchive"], documentCategory)
        add(["zip", "tar", "gz", "bz2", "xz", "zst", "7z", "rar", "dmg", "iso", "pkg",
             "xip", "tgz", "tbz2", "txz", "lz4", "lz", "lzma", "zipx", "cab", "war",
             "sit", "sitx", "cpio", "deb", "rpm", "msi", "snap", "flatpak",
             // disk images, firmware and virtual machine disks
             "sparsebundle", "sparseimage", "cdr", "toast", "img", "raw", "ipsw",
             "wim", "esd", "vmdk", "qcow2", "vdi", "vhd", "vhdx", "hdd", "hds",
             "ova", "ovf", "box", "pvm", "utm", "vmwarevm"], archiveCategory)
        add(["bak", "backup", "bkp", "backupbundle", "abbu"], backupCategory)
        add(["swift", "py", "js", "ts", "jsx", "tsx", "c", "cpp", "cc", "h", "hpp",
             "m", "mm", "java", "go", "rs", "rb", "php", "sh", "zsh", "bash", "pl",
             "lua", "kt", "scala", "cs", "vue", "svelte", "html", "htm", "css", "scss",
             "less", "json", "yaml", "yml", "toml", "xml", "plist", "lock", "map",
             "ipynb", "o", "a", "dylib", "so", "dll", "jar", "class", "wasm", "rlib",
             "rmeta", "pyc", "pyd", "node", "storyboard", "xib", "strings", "swiftmodule",
             "swiftdoc", "pcm", "d", "mod", "whl", "egg", "gem", "nupkg", "aar", "pdb",
             // Xcode/developer bundles and artifacts
             "xcodeproj", "xcworkspace", "playground", "xcassets", "xcarchive",
             "xcframework", "xcresult", "simruntime",
             "framework", "dsym", "nib", "car", "kext", "bundle", "plugin",
             "qlgenerator", "prefpane", "scpt", "scptd", "workflow",
             // git packfiles
             "pack", "idx"], codeCategory)
        add(["db", "sqlite", "sqlite3", "duckdb", "parquet", "csv", "tsv", "jsonl",
             "dat", "h5", "hdf5", "npy", "npz", "pt", "pth", "pb", "tflite", "onnx",
             "pkl", "pickle", "weights", "safetensors", "ckpt", "gguf", "arrow",
             "feather", "avro", "orc", "bin", "tfrecord", "lance", "joblib", "msgpack",
             "bson", "mat", "nc", "fits", "rds", "rdata", "dta", "h5ad",
             // Core ML and mobile databases
             "mlmodel", "mlmodelc", "mlpackage", "realm", "mdb"], dataCategory)
        add(["stl", "obj", "mtl", "fbx", "3mf", "gcode", "bgcode", "blend", "blend1",
             "usd", "usda", "usdc", "usdz", "gltf", "glb", "ply", "abc", "vdb", "dae",
             "x3d", "3ds", "c4d", "max", "ma", "mb", "hip", "hiplc", "hipnc", "lxo",
             "ztl", "zpr", "spp", "sbs", "sbsar",
             // CAD parts, assemblies, drawings and circuit boards
             "step", "stp", "iges", "igs", "f3d", "f3z", "sldprt", "sldasm", "slddrw",
             "dwg", "dxf", "skp", "3dm", "ipt", "iam", "idw", "catpart", "catproduct",
             "x_t", "x_b", "sat", "fcstd", "scad", "kicad_pcb", "kicad_sch", "kicad_pro",
             "brd", "gbr"], modelCategory)
        add(["pak", "uasset", "umap", "ucas", "utoc", "upk", "vpk", "bsa", "ba2",
             "unity3d", "assetbundle", "assets", "ress", "wad", "gcf", "pck", "rpa",
             // console and emulator images
             "nsp", "xci", "nds", "gba", "gbc", "sfc", "smc", "n64", "z64", "wbfs",
             "rvz", "cia", "chd"], gameCategory)
        add(["app", "appex", "ipa", "apk", "aab", "appimage"], appCategory)
        return table
    }()

    /// SF Symbol per category, for the tinted type icons in the file lists.
    /// Keyed by category ID plus the pseudo-IDs kindID can produce
    /// ("folder"); symbols reuse the app's existing metaphors (Applications
    /// matches the sidebar, folders match the outline).
    package nonisolated static func categorySymbol(forID id: String) -> String {
        switch id {
        case "cat-video": return "film.fill"
        case "cat-image": return "photo.fill"
        case "cat-audio": return "music.note"
        case "cat-docs": return "doc.text.fill"
        case "cat-archive": return "archivebox.fill"
        case "cat-backups": return "clock.arrow.circlepath"
        case "cat-code": return "chevron.left.forwardslash.chevron.right"
        case "cat-data": return "cylinder.split.1x2.fill"
        case "cat-3d": return "cube.fill"
        case "cat-games": return "gamecontroller.fill"
        case "cat-apps": return "square.grid.2x2.fill"
        case "cat-system": return "gearshape.fill"
        case "cat-summarized", "folder": return "folder.fill"
        default:
            return FileCategoryRules.isCustomCategoryID(id) ? "tag.fill" : "doc.fill"
        }
    }

    package nonisolated static let categoryKindsByID: [String: FileKind] = {
        let kinds = assignableCategories + [
            FileKind(id: "cat-system", displayName: "System Data"),
            FileKind(id: "cat-summarized", displayName: "Summarized Folders"),
        ]
        return Dictionary(uniqueKeysWithValues: kinds.map { ($0.id, $0) })
    }()

    /// Launch Services answers per extension never change within a run, and
    /// asking it per node made catalog builds take seconds.
    private nonisolated static let displayNameCache = DisplayNameCache()

    private nonisolated static func displayName(forExtension ext: String) -> String {
        displayNameCache.displayName(forExtension: ext) {
            if let description = FileTypeDescriptions.description(forExtension: ext) {
                return "\(description) (.\(ext))"
            }
            return ".\(ext)"
        }
    }
}

/// Human descriptions of file types ("PNG image") for the Types grouping.
/// Launch Services answers on Apple platforms; other shells install their
/// platform's lookup once at launch (the GTK app asks GIO, which reads
/// shared-mime-info).
package enum FileTypeDescriptions {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var provider: (@Sendable (String) -> String?)?

    package static func install(_ provider: @escaping @Sendable (_ fileExtension: String) -> String?) {
        lock.lock()
        defer { lock.unlock() }
        self.provider = provider
    }

    package nonisolated static func description(forExtension ext: String) -> String? {
        #if canImport(UniformTypeIdentifiers)
        if let type = UTType(filenameExtension: ext),
           let description = type.localizedDescription,
           !description.isEmpty {
            return description
        }
        return nil
        #else
        lock.lock()
        let provider = provider
        lock.unlock()
        return provider?(ext).flatMap { $0.isEmpty ? nil : $0 }
        #endif
    }
}

private final class DisplayNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var namesByExtension: [String: String] = [:]

    package func displayName(forExtension ext: String, resolve: () -> String) -> String {
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
