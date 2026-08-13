// Adapted from umputun/agterm and thdxg/macterm (MIT).

import AppKit

enum GhosttyClipboardAccess: Hashable, Sendable {
    case read
    case write
}

private struct GhosttyClipboardDecisions {
    private var choices: [GhosttyClipboardAccess: Bool] = [:]

    func decision(for access: GhosttyClipboardAccess) -> Bool? { choices[access] }
    mutating func remember(_ access: GhosttyClipboardAccess, allow: Bool) { choices[access] = allow }
}

@MainActor
final class GhosttyClipboardPromptController {
    static let shared = GhosttyClipboardPromptController()

    private struct PromptKey: Hashable {
        let access: GhosttyClipboardAccess
        let requester: ObjectIdentifier
    }

    private struct Pending {
        let requester: NSView
        var completions: [(Bool) -> Void]
    }

    private var decisions = GhosttyClipboardDecisions()
    private var pending: [PromptKey: Pending] = [:]

    func request(_ access: GhosttyClipboardAccess, requester: NSView, completion: @escaping (Bool) -> Void) {
        if let decision = decisions.decision(for: access) {
            completion(decision)
            return
        }
        let key = PromptKey(access: access, requester: ObjectIdentifier(requester))
        if pending[key] != nil {
            pending[key]?.completions.append(completion)
            return
        }
        pending[key] = Pending(requester: requester, completions: [completion])
        present(key)
    }

    private func present(_ key: PromptKey) {
        guard let request = pending[key] else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = key.access == .read
            ? "允许终端程序读取剪贴板吗？"
            : "允许终端程序写入剪贴板吗？"
        alert.informativeText = key.access == .read
            ? "终端中的程序正在通过 OSC 52 请求读取剪贴板，这可能暴露密码或其他已复制内容。"
            : "终端中的程序正在通过 OSC 52 请求替换剪贴板内容。"
        alert.addButton(withTitle: "允许")
        alert.addButton(withTitle: "拒绝")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "本次 TodoAgent 运行期间不再询问"

        let resolve: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            let allowed = response == .alertFirstButtonReturn
            if alert.suppressionButton?.state == .on {
                self.decisions.remember(key.access, allow: allowed)
            }
            let completions = self.pending.removeValue(forKey: key)?.completions ?? []
            completions.forEach { $0(allowed) }
        }
        if let window = request.requester.window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: resolve)
        } else {
            resolve(alert.runModal())
        }
    }
}
