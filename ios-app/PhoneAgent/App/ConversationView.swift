import SwiftUI
import MarkdownUI

struct ConversationView: View {
    @StateObject private var presentation: AgentPresentationAdapter
    let openSettings: () -> Void
    init(model: AgentViewModel, conversationID: UUID, openSettings: @escaping () -> Void) {
        _presentation = StateObject(wrappedValue: AgentPresentationAdapter(model: model, sessionID: conversationID))
        self.openSettings = openSettings
    }
    @State private var draft = ""
    @State private var followLatest = true
    @State private var focused = false
    private var session: AgentConversation? { presentation.session }
    private var running: Bool { presentation.running }
    private var canSend: Bool {
        !running && !presentation.stopping && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.count <= 2_000
    }
    var body: some View {
        Group {
            if let session {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Circle().fill(session.mode == .demo ? .teal : .blue).frame(width: 6, height: 6)
                        Text(session.mode == .demo ? "离线脚本 · 合成屏幕" : presentation.modelName).lineLimit(1)
                        Spacer()
                        Text(session.phase.label).foregroundStyle(session.phase == .awaitingApproval ? .orange : .secondary)
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 10)
                    if let navigation = presentation.activityNavigation {
                        Text(navigation.notice).font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 20).padding(.bottom, 8).accessibilityIdentifier("activityNavigationNotice")
                    }
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                if presentation.awaitingTaskConfirmation {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Label("Siri · 待确认", systemImage: "waveform").font(.headline)
                                        Text("任务已保存，尚未开始。请核对或编辑下方识别文本，再点“确认开始”。确认后会发送给当前模型；设备动作仍需逐次批准。")
                                            .foregroundStyle(.secondary)
                                        Text(session.draft).textSelection(.enabled).accessibilityIdentifier("siriRecognizedTask")
                                        Button("取消这份草稿", role: .cancel) {
                                            presentation.dismissPreparedTask()
                                            if !presentation.awaitingTaskConfirmation { draft = "" }
                                        }.accessibilityIdentifier("dismissSiriTask")
                                    }.padding(.vertical, 20)
                                } else if session.messages.isEmpty { welcome(session.mode) }
                                ForEach(session.messages) { message in
                                    messageView(message).id(message.id)
                                }
                                if running && presentation.pendingApproval == nil { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(presentation.status).font(.caption).foregroundStyle(.secondary) } }
                                Color.clear.frame(height: 1).id("latest")
                            }.padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: 780).frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("conversationMessages")
                        .scrollDismissesKeyboard(.interactively)
                        .simultaneousGesture(DragGesture().onChanged { _ in followLatest = false })
                        .onChange(of: session.messages) { _, _ in if followLatest { proxy.scrollTo("latest", anchor: .bottom) } }
                        .onChange(of: presentation.approvalID) { _, _ in if followLatest { proxy.scrollTo("latest", anchor: .bottom) } }
                        .onAppear { if presentation.activityNavigation == nil { proxy.scrollTo("latest", anchor: .bottom) } }
                        .task(id: presentation.activityNavigation?.id) {
                            guard let navigation = presentation.activityNavigation, let target = navigation.messageID else { return }
                            followLatest = false
                            await Task.yield()
                            proxy.scrollTo(target, anchor: .center)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if !followLatest {
                                Button { followLatest = true; withAnimation { proxy.scrollTo("latest", anchor: .bottom) } } label: { Image(systemName: "arrow.down").padding(12).background(.regularMaterial, in: Circle()) }
                                    .padding().accessibilityLabel("滚动到最新消息")
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .navigationTitle(session.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(action: openSettings) { Image(systemName: "gearshape") }.accessibilityLabel("设置") } }
                .onAppear { presentation.open(); draft = session.draft }
                .onDisappear { presentation.close() }
                .onChange(of: draft) { _, text in presentation.saveDraft(text) }
            } else { ContentUnavailableView("会话已删除", systemImage: "bubble.left") }
        }
    }
    private func welcome(_ mode: RunMode) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.blue).padding(.top, 34)
            Text("有什么可以一起完成？").font(.title2.bold())
            Text(mode == .demo ? "这个会话使用固定脚本，带你走一遍查看屏幕、确认点击和检查结果的流程。" : "描述你的问题或目标。Agent 的回复和每次工具执行都会保留在这里。")
                .foregroundStyle(.secondary)
            Button(mode == .demo ? "体验一次完整演示" : "帮我梳理一个任务的执行步骤") {
                draft = mode == .demo ? "查看演示画面，点击计数器一次，再检查结果" : "帮我梳理一个任务的执行步骤"
                focused = true
            }.buttonStyle(.bordered).accessibilityIdentifier("suggestedPrompt")
        }.padding(.bottom, 24)
    }
    @ViewBuilder private func messageView(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack { Spacer(minLength: 36); Text(message.text).textSelection(.enabled).padding(12).background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 18)).foregroundStyle(.primary) }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if !message.text.isEmpty {
                    Markdown(message.text).markdownTheme(.basic)
                        .markdownImageProvider(NoRemoteMarkdownImages()).markdownInlineImageProvider(NoRemoteInlineImages())
                        .textSelection(.enabled)
                } else if message.state == .streaming { Text("正在准备回复…").foregroundStyle(.secondary) }
                if message.state == .interrupted { Text("回复已中断").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            if let item = presentation.presentation(for: message) {
                ToolInvocationView(configuration: ToolInvocationConfiguration(tool: item.tool)) { toolPreview(item) }
            }
        case .notice:
            Text(message.text)
                .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                .padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var composer: some View {
        VStack(spacing: 10) {
            if let item = presentation.pendingApproval, let request = item.approval {
                ToolApprovalCard(configuration: ToolInvocationConfiguration(tool: item.tool,
                    onApprove: { _ = presentation.dispatch(.approve(step: item.identity, approvalID: request.id)) },
                    onDeny: { _ = presentation.dispatch(.deny(step: item.identity, approvalID: request.id)) })) {
                    toolPreview(item)
                }.id(request.id)
            }
            if let warning = presentation.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
            HStack(alignment: .bottom, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("随心输入").foregroundStyle(.tertiary).padding(.vertical, 10)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    MessageInput(text: $draft, focused: $focused, disabled: running || presentation.stopping, onSubmit: send)
                }
                if running {
                    Button { if let run = presentation.activeRun { presentation.dispatch(.stop(run: run)) } } label: { Image(systemName: "stop.fill").font(.body.bold()).frame(width: 38, height: 38).background(Color(uiColor: .label), in: Circle()).foregroundStyle(Color(uiColor: .systemBackground)) }
                        .accessibilityLabel("停止执行").accessibilityIdentifier("stopRun")
                } else if presentation.awaitingTaskConfirmation {
                    Button("确认开始") { sendConfirmedTask() }
                        .buttonStyle(.borderedProminent).disabled(!canSend)
                        .accessibilityIdentifier("confirmSiriTask")
                } else {
                    Button { send() } label: { Image(systemName: "arrow.up").font(.body.bold()).frame(width: 38, height: 38).background(.blue, in: Circle()).foregroundStyle(.white) }
                        .disabled(!canSend)
                        .accessibilityLabel("发送").accessibilityIdentifier("sendMessage")
                }
            }.padding(.horizontal, 15).padding(.vertical, 6).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8).background(.bar)
    }
    @ViewBuilder private func toolPreview(_ item: ToolPresentation) -> some View {
        if let image = item.image, let uiImage = UIImage(data: image.png) {
            DisclosureGroup {
                Image(uiImage: uiImage).resizable().scaledToFit().frame(maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(image.isDemo ? "演示合成屏幕，不是真机截图" : "当前步骤的设备截图")
            } label: {
                Text(image.isDemo ? "查看合成截图" : "查看本轮截图")
                    .accessibilityIdentifier(item.approval == nil ? "toolScreenshot-result" : "toolScreenshot-approval")
            }.font(.footnote).tint(.secondary)
        } else if item.tool.name == "screenshot", item.tool.state == .succeeded {
            Text("截图预览已释放；保留工具记录。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func send() {
        guard !presentation.awaitingTaskConfirmation else { return }
        sendConfirmedTask()
    }
    private func sendConfirmedTask() {
        guard canSend else { return }
        // The Send button and keyboard submission both authorize this request.
        if presentation.dispatch(.send(sessionID: presentation.sessionID, text: draft, cloudConsent: true)) {
            draft = ""; focused = false; followLatest = true
        }
    }
}

/// A multiline composer whose Return key submits while preserving multiline
/// text insertion and input-method composition.
private struct MessageInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let disabled: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.returnKeyType = .send
        view.enablesReturnKeyAutomatically = true
        view.accessibilityLabel = "随心输入"
        view.accessibilityIdentifier = "messageInput"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text, view.markedTextRange == nil { view.text = text }
        view.isEditable = !disabled
        view.isUserInteractionEnabled = !disabled
        let coordinator = context.coordinator
        if focused && !disabled && !view.isFirstResponder {
            DispatchQueue.main.async { [weak view] in
                guard coordinator.parent.focused, !coordinator.parent.disabled, view?.window != nil else { return }
                view?.becomeFirstResponder()
            }
        } else if (!focused || disabled) && view.isFirstResponder {
            DispatchQueue.main.async { [weak view] in
                guard !coordinator.parent.focused || coordinator.parent.disabled else { return }
                view?.resignFirstResponder()
            }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let lineHeight = uiView.font?.lineHeight ?? 20
        let insets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(max(height, lineHeight + insets), lineHeight * 5 + insets))
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MessageInput
        init(_ parent: MessageInput) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.focused { parent.focused = true }
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.focused { parent.focused = false }
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", textView.markedTextRange == nil else { return true }
            if !parent.disabled { parent.onSubmit() }
            return false
        }
    }
}

private struct NoRemoteMarkdownImages: MarkdownUI.ImageProvider {
    func makeImage(url: URL?) -> some View { Label("外部图片未自动加载", systemImage: "photo").font(.caption).foregroundStyle(.secondary) }
}
private struct NoRemoteInlineImages: MarkdownUI.InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image { Image(systemName: "photo") }
}
