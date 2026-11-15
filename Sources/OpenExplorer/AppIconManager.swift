import AppKit

/// Keeps the Dock icon in sync with System Settings › Appearance › Icon & widget style
/// (Default / Dark / Clear / Tinted, each optionally "Automatic" = follows light/dark mode).
///
/// The bundle's static .icns covers Finder/Launchpad; this updates the running app's Dock icon.
@MainActor
final class AppIconManager: NSObject {
    static let shared = AppIconManager()

    private static let themeKey = "AppleIconAppearanceTheme"
    private var currentKey: String?
    private var timer: Timer?
    private var appearanceObservation: NSKeyValueObservation?

    func start() {
        apply()

        // Light/dark mode switches matter for the "Automatic" variants.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async { AppIconManager.shared.apply() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsMayHaveChanged),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
        // Accent colour changes affect the Tinted style.
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsMayHaveChanged),
            name: NSColor.systemColorsDidChangeNotification, object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(settingsMayHaveChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil
        )
        // The icon style itself has no public change notification; a cheap poll catches it.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { AppIconManager.shared.apply() }
        }
    }

    @objc private func settingsMayHaveChanged() {
        apply()
    }

    /// Reads the system icon style and swaps the Dock icon if it changed.
    func apply() {
        let style = currentStyle()
        guard style.cacheKey != currentKey else { return }
        currentKey = style.cacheKey
        NSApp.applicationIconImage = style == .standard && Bundle.main.bundlePath.hasSuffix(".app")
            ? nil  // use the bundle's .icns as-is
            : IconRenderer.image(style, pixels: 512)
    }

    func currentStyle() -> AppIconStyle {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let theme = (CFPreferencesCopyAppValue(Self.themeKey as CFString, kCFPreferencesAnyApplication) as? String) ?? ""
        let systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // Values look like "RegularDark", "ClearAutomatic", "TintedLight", ...
        let dark = theme.hasSuffix("Dark") || (theme.hasSuffix("Automatic") && systemIsDark)

        if theme.hasPrefix("Clear") { return .clear(dark: dark) }
        if theme.hasPrefix("Tinted") { return .tinted(NSColor.controlAccentColor, dark: dark) }
        return dark ? .dark : .standard
    }
}
