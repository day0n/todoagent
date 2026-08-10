import AppKit
import SwiftUI

/// The monochrome TodoAgent mark derived from the user-provided Valibot SVG.
///
/// It ships as a vector PDF so the SwiftPM build keeps sharp edges at every
/// sidebar, empty-state, and Retina scale. The artwork owns its black/white
/// palette and therefore must not be treated as a template image.
@MainActor
enum TodoAgentBrandMark {
    static let resourceName = "todoagent-agent-mark"

    private static var cachedImage: NSImage?

    static func image() -> NSImage? {
        if let cachedImage { return cachedImage }
        guard let url = TodoAgentResourceBundle.url(
            forResource: resourceName,
            withExtension: "pdf"
        ),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = false
        cachedImage = image
        return image
    }
}

struct TodoAgentBrandMarkView: View {
    var size: CGFloat

    var body: some View {
        if let image = TodoAgentBrandMark.image() {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.72, weight: .semibold))
                .foregroundStyle(TodoAgentUI.primaryText)
                .frame(width: size, height: size)
        }
    }
}
