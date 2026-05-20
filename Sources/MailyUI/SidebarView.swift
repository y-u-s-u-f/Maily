import SwiftUI

// MARK: - Sidebar item model

public enum SidebarItem: String, CaseIterable, Hashable {
    case inbox   = "Inbox"
    case starred = "Starred"
    case sent    = "Sent"
    case drafts  = "Drafts"
}

// MARK: - SidebarView

public struct SidebarView: View {
    @Binding var selection: SidebarItem

    public init(selection: Binding<SidebarItem>) {
        _selection = selection
    }

    private static let systemImageNames: [SidebarItem: String] = [
        .inbox:   "tray",
        .starred: "star",
        .sent:    "paperplane",
        .drafts:  "doc",
    ]

    public var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(SidebarItem.allCases, id: \.self) { item in
                    Label(item.rawValue, systemImage: Self.systemImageNames[item] ?? "folder")
                        .accessibilityIdentifier("sidebar-\(item.rawValue.lowercased())")
                }
            }
            // Labels section header — empty for now
            Section("Labels") { }
        }
        .accessibilityIdentifier("SidebarList")
        .listStyle(.sidebar)
    }
}
