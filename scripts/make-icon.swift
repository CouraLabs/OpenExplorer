// Renders the Open Explorer app icon PNGs using the app's own IconRenderer.
// Usage:
//   swiftc -parse-as-library scripts/make-icon.swift Sources/OpenExplorer/IconRenderer.swift -o build/make-icon
//   build/make-icon <output-dir>
// Writes icon-standard.png, icon-dark.png, icon-clear.png, icon-tinted.png (1024×1024).
import AppKit

@main
struct MakeIcon {
    static func main() {
        guard CommandLine.arguments.count > 1 else {
            print("usage: make-icon <output-dir>")
            exit(1)
        }
        let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let styles: [(String, AppIconStyle)] = [
            ("standard", .standard),
            ("dark", .dark),
            ("clear", .clear(dark: true)),
            ("tinted", .tinted(NSColor.systemBlue, dark: true)),
        ]
        for (name, style) in styles {
            let png = IconRenderer.render(style).representation(using: .png, properties: [:])!
            try! png.write(to: dir.appendingPathComponent("icon-\(name).png"))
        }
        print("Wrote icons to \(dir.path)")
    }
}
