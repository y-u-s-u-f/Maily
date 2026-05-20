// Hosts the SwiftUI PaletteView inside a HUD-style NSPanel that floats above
// the main window without stealing activation. The controller is reusable:
// each `showPalette()` call builds a fresh PaletteViewModel from the current
// CommandContext so stale results never reappear.
import AppKit
import SwiftUI
import MailyCore

@MainActor
public final class PaletteWindowController: NSWindowController, NSWindowDelegate {
    private let registry: CommandRegistry
    private let contextProvider: @MainActor () -> CommandContext
    private var currentViewModel: PaletteViewModel?

    public init(
        registry: CommandRegistry,
        contextProvider: @escaping @MainActor () -> CommandContext
    ) {
        self.registry = registry
        self.contextProvider = contextProvider

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func showPalette() {
        guard let window = self.window else { return }

        // Always rebuild the VM so the context snapshot is fresh.
        let vm = PaletteViewModel(registry: registry, context: contextProvider())
        currentViewModel = vm

        let view = PaletteView(
            vm: vm,
            onActivated: { [weak self] in self?.dismiss() },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        window.contentView = NSHostingView(rootView: view)

        if let screen = NSScreen.main ?? window.screen {
            let frame = screen.visibleFrame
            let size = window.frame.size
            let origin = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2 + 80
            )
            window.setFrameOrigin(origin)
        }

        window.makeKeyAndOrderFront(nil)
    }

    public func dismiss() {
        window?.orderOut(nil)
        currentViewModel = nil
    }

    // MARK: - NSWindowDelegate

    public func windowDidResignKey(_ notification: Notification) {
        // Click-outside-to-dismiss without forcing activation churn.
        dismiss()
    }
}
