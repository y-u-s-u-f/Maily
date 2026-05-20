// HUD-style command palette UI. A search field at the top, a scrolling list of
// matching commands below, and a footer hinting at the basic key affordances.
// All keyboard handling lives here so the hosting NSPanel only needs to wire
// up the dismiss/activate callbacks.
import SwiftUI
import MailyCore
// `CoreShortcut` is a file-external typealias for `MailyCore.KeyboardShortcut`
// defined in CoreShortcutAlias.swift; that file deliberately avoids importing
// SwiftUI so the typealias resolves unambiguously.

struct PaletteView: View {
    @ObservedObject var vm: PaletteViewModel
    var onActivated: () -> Void
    var onDismiss: () -> Void

    @FocusState private var queryFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Run a command…", text: $vm.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .focused($queryFieldFocused)
                .onSubmit { activate() }

            Divider()

            ScrollViewReader { proxy in
                List {
                    ForEach(Array(vm.results.enumerated()), id: \.element.id) { idx, cmd in
                        PaletteRow(command: cmd, isSelected: idx == vm.selectedIndex)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .listRowSeparator(.hidden)
                            .id(cmd.id)
                            .contentShape(Rectangle())
                            .onTapGesture { activate(index: idx) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: vm.selectedIndex) { _, newValue in
                    guard vm.results.indices.contains(newValue) else { return }
                    proxy.scrollTo(vm.results[newValue].id, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .onAppear { queryFieldFocused = true }
        .onKeyPress(.downArrow) {
            vm.moveSelection(1); return .handled
        }
        .onKeyPress(.upArrow) {
            vm.moveSelection(-1); return .handled
        }
        .onKeyPress(.escape) {
            onDismiss(); return .handled
        }
        .onKeyPress(.return) {
            activate(); return .handled
        }
    }

    private func activate(index: Int? = nil) {
        if let index { vm.selectedIndex = index }
        Task {
            await vm.activateSelected()
            onActivated()
        }
    }
}

private struct PaletteRow: View {
    let command: Command
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                    .font(.system(size: 14, weight: .medium))
                if let subtitle = command.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let shortcut = command.defaultShortcut {
                Text(shortcutDescription(shortcut))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
    }
}

/// Build a "⌘⇧K"-style description. CoreShortcut has no built-in
/// description, so this lives here as a pure helper.
func shortcutDescription(_ shortcut: CoreShortcut) -> String {
    var parts = ""
    if shortcut.modifiers.contains(.control) { parts += "⌃" }
    if shortcut.modifiers.contains(.option)  { parts += "⌥" }
    if shortcut.modifiers.contains(.shift)   { parts += "⇧" }
    if shortcut.modifiers.contains(.command) { parts += "⌘" }
    let label: String
    switch shortcut.key {
    case "Enter":     label = "⏎"
    case "Escape":    label = "⎋"
    case "Backspace": label = "⌫"
    case "Tab":       label = "⇥"
    default:          label = shortcut.key.uppercased()
    }
    return parts + label
}
