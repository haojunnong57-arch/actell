import SwiftUI

/// Uses the same native disclosure pattern as the adjacent tool cards.
struct ReasoningMessageView: View {
    let reasoning: ReasoningMessage
    let messageID: UUID
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(reasoning.text).font(.callout).foregroundStyle(Color.secondary.opacity(0.85))
                .textSelection(.enabled)
                .accessibilityIdentifier("reasoningContent-\(messageID)")
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                MessageHeaderIcon(systemName: "brain")
                Text("思考").font(.body)
                Spacer(minLength: 8)
            }.foregroundStyle(.secondary)
                .accessibilityIdentifier("reasoningDisclosure-\(messageID)")
        }.tint(.secondary).padding(.vertical, 4)
    }
}
