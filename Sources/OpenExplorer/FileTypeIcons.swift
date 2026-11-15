import AppKit

/// Which icon set the file list and tree use.
enum FileIconTheme: String, CaseIterable, Identifiable {
    case vscode, macOS
    var id: Self { self }
    var title: String { self == .vscode ? "VS Code" : "macOS" }

    static var current: FileIconTheme {
        get { FileIconTheme(rawValue: UserDefaults.standard.string(forKey: "fileIconTheme") ?? "") ?? .vscode }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "fileIconTheme") }
    }
}

/// File-type icons from vscode-icons (MIT, https://github.com/vscode-icons/vscode-icons),
/// bundled by `scripts/fetch-vscode-icons.sh` into Resources/vscode-icons.
///
/// Lookup order (same as the editors): exact file name → longest suffix ("component.ts" before "ts")
/// → default file. Folders match by name, with an "opened" variant for expanded tree nodes.
final class FileTypeIcons {
    static let shared = FileTypeIcons()

    private struct Variant: Decodable {
        let stems: [String: String]
        let suffixes: [String: String]
        let folders: [String: [String]]
        let defaultFile: String
        let defaultFolder: [String]
    }

    private struct Mapping: Decodable {
        let dark: Variant
        let light: Variant
    }

    private struct Lookup {
        let exactStems: [String: String]
        let lowerStems: [String: String]
        let suffixes: [String: String]
        let folders: [String: [String]]
        let defaultFile: String
        let defaultFolder: [String]

        init(_ v: Variant) {
            exactStems = v.stems
            lowerStems = Dictionary(v.stems.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
            suffixes = Dictionary(v.suffixes.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
            folders = v.folders
            defaultFile = v.defaultFile
            defaultFolder = v.defaultFolder
        }
    }

    private let iconsDirectory: URL?
    private let dark: Lookup?
    private let light: Lookup?
    private let images = NSCache<NSString, NSImage>()

    var isAvailable: Bool { dark != nil }

    private init() {
        let base = Bundle.main.resourceURL?.appendingPathComponent("vscode-icons")
        if let base,
           let data = try? Data(contentsOf: base.appendingPathComponent("mapping.json")),
           let mapping = try? JSONDecoder().decode(Mapping.self, from: data) {
            iconsDirectory = base.appendingPathComponent("icons")
            dark = Lookup(mapping.dark)
            light = Lookup(mapping.light)
        } else {
            iconsDirectory = nil
            dark = nil
            light = nil
        }
    }

    private var lookup: Lookup? {
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? dark : (light ?? dark)
    }

    /// SVG file name for a file.
    func iconName(forFile name: String) -> String? {
        guard let lookup else { return nil }
        if let icon = lookup.exactStems[name] ?? lookup.lowerStems[name.lowercased()] { return icon }
        // Try every suffix after a dot, longest first: "app.component.ts" → "component.ts" → "ts".
        let lower = name.lowercased()
        var index = lower.startIndex
        while let dot = lower[index...].firstIndex(of: ".") {
            let suffix = String(lower[lower.index(after: dot)...])
            if !suffix.isEmpty, let icon = lookup.suffixes[suffix] { return icon }
            index = lower.index(after: dot)
        }
        return lookup.defaultFile
    }

    /// SVG file name for a folder.
    func iconName(forFolder name: String, expanded: Bool) -> String? {
        guard let lookup else { return nil }
        let pair = lookup.folders[name.lowercased()] ?? lookup.defaultFolder
        return expanded && pair.count > 1 ? pair[1] : pair.first
    }

    /// 16×16 image for an icon file name (cached; SVGs are drawn natively by NSImage).
    func image(named fileName: String) -> NSImage? {
        if let cached = images.object(forKey: fileName as NSString) { return cached }
        guard let url = iconsDirectory?.appendingPathComponent(fileName),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        images.setObject(image, forKey: fileName as NSString)
        return image
    }
}
