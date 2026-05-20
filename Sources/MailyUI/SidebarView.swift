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
        List(SidebarItem.allCases, id: \.self, selection: $selection) { item in
            Label(item.rawValue, systemImage: Self.systemImageNames[item] ?? "folder")
                .accessibilityIdentifier("sidebar-\(item.rawValue.lowercased())")
        }
        .accessibilityIdentifier("SidebarList")
        // Labels section header — empty for now
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Labels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
        }
        .listStyle(.sidebar)
    }
}
