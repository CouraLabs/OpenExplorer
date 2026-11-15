import AppKit
import Foundation

/// One row in the right-hand detail list.
struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    /// True for real, navigable folders (packages such as .app bundles are treated as files, like Finder does).
    let isFolder: Bool
    let isHidden: Bool
    let size: Int64
    let created: Date
    let modified: Date
    let kind: String
    /// Search results: folder relative to the search root ("" = the root itself).
    var location = ""
    /// Contents search: "line: text" of the first match.
    var match: String?
    /// Bundles such as .app that macOS shows as files.
    var isPackage = false

    var id: URL { url }

    /// Folders sort before/after files consistently when sorting by size.
    var sizeSortKey: Int64 { isFolder ? -1 : size }

    var formattedSize: String {
        isFolder ? "" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

enum FileSystem {
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
        .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        .localizedTypeDescriptionKey,
    ]

    private static func options(showHidden: Bool) -> FileManager.DirectoryEnumerationOptions {
        showHidden ? [] : [.skipsHiddenFiles]
    }

    /// Lists every file and folder inside `directory`.
    static func listItems(in directory: URL, showHidden: Bool) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: options(showHidden: showHidden)
        )
        return urls.compactMap(makeItem)
    }

    /// Lists only the sub-folders of `directory`, sorted by name (used by the tree).
    static func listFolders(in directory: URL, showHidden: Bool) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: options(showHidden: showHidden)
        )) ?? []
        return urls
            .filter(isFolder)
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Directory (following symlinks) that is not a package.
    static func isFolder(_ url: URL) -> Bool {
        var target = url
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            target = url.resolvingSymlinksInPath()
        }
        guard let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true
    }

    static func makeItem(_ url: URL) -> FileItem? {
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else { return nil }
        let folder: Bool
        if values.isSymbolicLink == true {
            folder = isFolder(url)
        } else {
            folder = values.isDirectory == true && values.isPackage != true
        }
        return FileItem(
            url: url,
            name: url.lastPathComponent,
            isFolder: folder,
            isHidden: values.isHidden == true || url.lastPathComponent.hasPrefix("."),
            size: Int64(values.fileSize ?? 0),
            created: values.creationDate ?? .distantPast,
            modified: values.contentModificationDate ?? .distantPast,
            kind: folder ? "Folder" : (values.localizedTypeDescription ?? "Document"),
            isPackage: values.isPackage == true
        )
    }

    /// Returns a URL in `directory` that does not exist yet, e.g. "name - Copy (2).txt".
    static func availableCopyURL(for name: String, in directory: URL) -> URL {
        let first = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        let ns = name as NSString
        let stem = ns.deletingPathExtension, ext = ns.pathExtension
        return availableURL(in: directory, ext: ext) { $0 == 1 ? "\(stem) - Copy" : "\(stem) - Copy (\($0))" }
    }

    /// Returns "New Folder", "New Folder (2)", ... whichever is free.
    static func availableNewURL(stem: String, ext: String, in directory: URL) -> URL {
        availableURL(in: directory, ext: ext) { $0 == 1 ? stem : "\(stem) (\($0))" }
    }

    private static func availableURL(in directory: URL, ext: String, stem: (Int) -> String) -> URL {
        var i = 1
        while true {
            let name = ext.isEmpty ? stem(i) : "\(stem(i)).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}

enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    /// Finder's icon for a path.
    static func systemIcon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = (NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 16, height: 16)
        cache.setObject(image, forKey: key)
        return image
    }

    /// Icon for a list row, following the selected icon theme.
    static func icon(for item: FileItem) -> NSImage {
        themedIcon(for: item.url, isFolder: item.isFolder, isPackage: item.isPackage, expanded: false)
    }

    /// Icon for any path, following the selected icon theme.
    static func icon(for url: URL, isFolder: Bool? = nil, expanded: Bool = false) -> NSImage {
        let folder = isFolder ?? FileSystem.isFolder(url)
        let package = !folder && (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
        return themedIcon(for: url, isFolder: folder, isPackage: package, expanded: expanded)
    }

    private static func themedIcon(for url: URL, isFolder: Bool, isPackage: Bool, expanded: Bool) -> NSImage {
        let icons = FileTypeIcons.shared
        // Apps and other bundles keep their real icon.
        guard FileIconTheme.current == .vscode, icons.isAvailable, !isPackage else { return systemIcon(for: url) }
        let name = isFolder
            ? icons.iconName(forFolder: url.lastPathComponent, expanded: expanded)
            : icons.iconName(forFile: url.lastPathComponent)
        return name.flatMap(icons.image(named:)) ?? systemIcon(for: url)
    }
}
