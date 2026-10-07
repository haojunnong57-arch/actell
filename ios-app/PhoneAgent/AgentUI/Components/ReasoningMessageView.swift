import SwiftUI

/// Uses the same native disclosure pattern as the adjacent tool cards.
struct ReasoningMessageView: View {
    let reasoning: ReasoningMessage
    let messageID: UUID
    @State private var expanded = false
    var body: some View {
        ConversationDisclosureGroup(isExpanded: $expanded) {
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

private struct ConversationDisclosureActionKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
extension EnvironmentValues {
    var conversationDisclosureChanged: () -> Void {
        get { self[ConversationDisclosureActionKey.self] }
        set { self[ConversationDisclosureActionKey.self] = newValue }
    }
}

/// Pause following before expansion changes layout, including nested tool folds.
struct ConversationDisclosureGroup<Content: View, Label: View>: View {
    @Environment(\.conversationDisclosureChanged) private var changed
    @State private var expanded = false
    private let externalExpansion: Binding<Bool>?
    private let content: Content
    private let label: Label
    init(isExpanded: Binding<Bool>? = nil, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        externalExpansion = isExpanded
        self.content = content()
        self.label = label()
    }
    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { externalExpansion?.wrappedValue ?? expanded },
            set: { value in
                changed()
                if let externalExpansion { externalExpansion.wrappedValue = value }
                else { expanded = value }
            }
        )) { content } label: { label }
    }
}
