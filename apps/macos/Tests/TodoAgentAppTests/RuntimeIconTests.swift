import AppKit
import Testing
@testable import TodoAgentApp

@Suite("Runtime brand marks")
@MainActor
struct RuntimeIconTests {
    /// Guards the resource lookup itself. The PDFs are loaded by filename from
    /// `Bundle.module`, so a renamed or unbundled file fails only at runtime and
    /// shows up as a blank icon rather than a build error.
    @Test("bundled runtimes resolve in both appearances", arguments: [
        RuntimeKind.codex, .claude, .cursor,
    ])
    func loadsBundledMark(kind: RuntimeKind) throws {
        for dark in [false, true] {
            let image = try #require(
                RuntimeIcon.image(for: kind, dark: dark),
                "\(kind.rawValue) should ship a brand mark (dark: \(dark))"
            )
            // Brand colors have to survive, so these must not be templates —
            // a template would be repainted with the row's status tint.
            #expect(image.isTemplate == false)
            #expect(image.size.width > 0)
            #expect(image.size.height > 0)
        }
    }

    /// The near-black Codex and Cursor marks are invisible on a dark canvas, so
    /// each needs its own light-filled asset. Claude's orange holds contrast on
    /// both and deliberately shares one file.
    @Test("only the near-black marks carry a separate dark variant")
    func darkVariantsExistWhereContrastDemandsThem() {
        for kind in [RuntimeKind.codex, .cursor] {
            #expect(
                RuntimeIcon.resourceName(for: kind, dark: false)
                    != RuntimeIcon.resourceName(for: kind, dark: true),
                "\(kind.rawValue) needs distinct light and dark artwork"
            )
        }
        #expect(
            RuntimeIcon.resourceName(for: .claude, dark: false)
                == RuntimeIcon.resourceName(for: .claude, dark: true)
        )
    }

    @Test("runtimes without artwork fall back to an SF Symbol")
    func kiroHasNoBundledMark() {
        #expect(RuntimeIcon.image(for: .kiro, dark: false) == nil)
        #expect(RuntimeIcon.image(for: .kiro, dark: true) == nil)
    }
}
