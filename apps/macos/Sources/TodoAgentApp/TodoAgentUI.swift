import AppKit
import SwiftUI

/// Shared visual constants for the native preview.
///
/// Keeping these values in one place makes the three-pane interface feel like
/// one product and lets future design passes adjust density consistently.
enum TodoAgentUI {
    static let sidebarIdealWidth: CGFloat = 260
    static let sidebarMaximumWidth: CGFloat = 320
    static let inspectorIdealWidth: CGFloat = 440

    // A quiet, warm-neutral palette keeps the calendar, board, and assistant
    // visually related while still adapting cleanly to dark appearances.
    static let canvasBackground = adaptiveColor(
        light: NSColor(srgbRed: 0.984, green: 0.984, blue: 0.976, alpha: 1),
        dark: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.114, alpha: 1)
    )
    static let sidebarBackground = adaptiveColor(
        light: NSColor(srgbRed: 0.969, green: 0.969, blue: 0.961, alpha: 1),
        dark: NSColor(srgbRed: 0.145, green: 0.145, blue: 0.137, alpha: 1)
    )
    static let surfaceBackground = adaptiveColor(
        light: NSColor(srgbRed: 1, green: 1, blue: 0.996, alpha: 1),
        dark: NSColor(srgbRed: 0.180, green: 0.180, blue: 0.169, alpha: 1)
    )
    static let selectionBackground = adaptiveColor(
        light: NSColor(srgbRed: 0.937, green: 0.933, blue: 0.922, alpha: 1),
        dark: NSColor(srgbRed: 0.231, green: 0.231, blue: 0.216, alpha: 1)
    )
    static let primaryText = adaptiveColor(
        light: NSColor(srgbRed: 0.216, green: 0.208, blue: 0.184, alpha: 1),
        dark: NSColor(srgbRed: 0.941, green: 0.941, blue: 0.925, alpha: 1)
    )
    static let secondaryText = adaptiveColor(
        light: NSColor(srgbRed: 0.471, green: 0.467, blue: 0.455, alpha: 1),
        dark: NSColor(srgbRed: 0.678, green: 0.678, blue: 0.651, alpha: 1)
    )
    static let hairline = adaptiveColor(
        light: NSColor(srgbRed: 0.906, green: 0.906, blue: 0.894, alpha: 1),
        dark: NSColor(srgbRed: 0.286, green: 0.286, blue: 0.271, alpha: 1)
    )
    static let shadowColor = adaptiveColor(
        light: NSColor(white: 0, alpha: 0.10),
        dark: NSColor(white: 0, alpha: 0.28)
    )

    static let boardPadding: CGFloat = 14
    static let boardSpacing: CGFloat = 12
    static let columnMinimumWidth: CGFloat = 270
    static let columnMaximumWidth: CGFloat = 340

    static let panelRadius: CGFloat = 14
    static let cardRadius: CGFloat = 11
    static let cardPadding: CGFloat = 14
    static let compactSpacing: CGFloat = 6
    static let standardSpacing: CGFloat = 10
    static let sectionSpacing: CGFloat = 14

    static let sidebarFooterGradientHeight: CGFloat = 64
    static let sidebarNavigationTopSpacing: CGFloat = 8
    static let floatingButtonSize: CGFloat = 46
    static let composerRadius: CGFloat = 16

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            }
        )
    }
}
