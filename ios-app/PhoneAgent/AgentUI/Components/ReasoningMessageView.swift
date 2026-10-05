import SwiftUI

/// Uses the same native disclosure pattern as the adjacent tool cards.
struct ReasoningMessageView: View {
    let reasoning: ReasoningMessage
    let messageID: UUID
    @State private var expanded = false
    private var status: String {
        switch reasoning.state {
        case .streaming: return "接收中"
        case .complete: return "已完成"
        case .interrupted: return "已中断"
        case .failed: return "生成失败"
        }
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text("服务商返回的思考内容或摘要").font(.caption).foregroundStyle(.secondary)
                Text(reasoning.text).font(.callout).textSelection(.enabled)
                    .accessibilityIdentifier("reasoningContent-\(messageID)")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile").accessibilityHidden(true)
                Text("思考内容")
                Spacer(minLength: 8)
                Text(status).font(.caption)
            }.foregroundStyle(.secondary)
                .accessibilityIdentifier("reasoningDisclosure-\(messageID)")
        }.tint(.secondary).padding(.vertical, 4)
    }
}
