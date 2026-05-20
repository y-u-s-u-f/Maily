import SwiftUI

public struct StatusBarView: View {
    @ObservedObject var viewModel: SyncStatusViewModel

    public init(viewModel: SyncStatusViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(viewModel.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
        }
        .accessibilityIdentifier("StatusBar")
    }
}
