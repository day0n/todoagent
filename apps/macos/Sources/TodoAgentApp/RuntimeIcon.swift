import AppKit
import SwiftUI

enum TodoAgentResourceBundle {
    private static let bundleName = "TodoAgentNative_TodoAgentApp"

    /// SwiftPM's generated `Bundle.module` accessor looks beside the app
    /// bundle, while a valid signed macOS app must keep resources under
    /// Contents/Resources. Prefer that packaged location and only evaluate the
    /// generated accessor for `swift run` and tests.
    static func url(forResource name: String, withExtension extensionName: String) -> URL? {
        if let resources = Bundle.main.resourceURL,
           let packagedBundle = Bundle(
               url: resources.appendingPathComponent(bundleName + ".bundle")
           ),
           let url = packagedBundle.url(forResource: name, withExtension: extensionName)
        {
            return url
        }

        return Bundle.module.url(forResource: name, withExtension: extensionName)
    }
}

/// Loads the bundled brand marks for the CLI runtimes.
///
/// The glyphs ship as vector PDFs rather than an asset catalog because this
/// target is built with SwiftPM, which copies `.xcassets` verbatim instead of
/// running `actool`. An uncompiled catalog has no `Assets.car`, so
/// `Image("Name")` would silently resolve to nothing. Loading the PDF directly
/// keeps the artwork vector and works under both `swift build` and the
/// packaged app.
///
/// The marks keep their own brand colors, so they are deliberately *not*
/// template images: runtime status is carried by the status dot, the status
/// label, and the tinted well behind the icon instead.
@MainActor
enum RuntimeIcon {
    /// Keyed by resource name because a runtime can ship two variants. Cached
    /// because SwiftUI re-evaluates these rows on every state change and
    /// decoding a PDF per pass is pure waste.
    private static var cache: [String: NSImage] = [:]

    /// Returns the brand mark, or `nil` for runtimes that still use an SF Symbol.
    static func image(for kind: RuntimeKind, dark: Bool) -> NSImage? {
        guard let name = resourceName(for: kind, dark: dark) else { return nil }
        if let cached = cache[name] { return cached }
        guard let url = TodoAgentResourceBundle.url(forResource: name, withExtension: "pdf"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = false
        cache[name] = image
        return image
    }

    static func resourceName(for kind: RuntimeKind, dark: Bool) -> String? {
        switch kind {
        // Claude's orange holds its contrast on both canvases, so one asset
        // covers both appearances.
        case .claude: "runtime-claude"
        // These two ship near-black marks (#111 and #26251e) that all but
        // disappear on a dark canvas, so each has a light-filled variant.
        case .codex: dark ? "runtime-codex-dark" : "runtime-codex"
        case .cursor: dark ? "runtime-cursor-dark" : "runtime-cursor"
        // Kiro has no brand mark in the repository yet.
        case .kiro: nil
        }
    }
}

/// A runtime's icon at a fixed size, preferring the bundled brand mark and
/// falling back to an SF Symbol that still inherits the caller's tint.
struct RuntimeIconView: View {
    @Environment(\.colorScheme) private var colorScheme

    let kind: RuntimeKind
    let fallbackSymbol: String
    var glyphSize: CGFloat = 17

    var body: some View {
        if let image = RuntimeIcon.image(for: kind, dark: colorScheme == .dark) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: glyphSize, height: glyphSize)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.title3)
        }
    }
}
