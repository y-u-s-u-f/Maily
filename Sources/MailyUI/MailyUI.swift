import SwiftUI
import MailyCore

public struct PlaceholderView: View {
    public init() {}
    public var body: some View {
        VStack(spacing: 12) {
            Text("Maily")
                .font(.system(size: 36, weight: .semibold, design: .rounded))
            Text("MailyCore \(MailyCore.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
