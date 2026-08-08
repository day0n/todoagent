import SwiftUI

/// Shared visual constants for the native preview.
///
/// Keeping these values in one place makes the three-pane interface feel like
/// one product and lets future design passes adjust density consistently.
enum TodoAgentUI {
    static let sidebarIdealWidth: CGFloat = 260
    static let sidebarMaximumWidth: CGFloat = 320
    static let inspectorIdealWidth: CGFloat = 360

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
}
