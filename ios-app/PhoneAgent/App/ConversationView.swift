import SwiftUI
import MarkdownUI

struct ConversationView: View {
    @State private var browsingModels = false
    @StateObject private var presentation: AgentPresentationAdapter
    let openProviders: () -> Void
    init(model: AgentViewModel, conversationID: UUID, openProviders: @escaping () -> Void) {
        _presentation = StateObject(wrappedValue: AgentPresentationAdapter(model: model, sessionID: conversationID))
        self.openProviders = openProviders
    }
    @State private var draft = ""
    @State private var choosingModel = false
    @State private var customModel = ""
    @State private var followLatest = true
    @State private var userScrolling = false
    @State private var lastMessageVisible = false
    @State private var focused = false
    @State private var scrollPosition = ScrollPosition()
    @State private var deferredViewportShift: CGFloat = 0
    @State private var viewportDiagnostic = ""
    @State private var importingAttachments = false
    @State private var sendingAttachments = false
    @State private var attachmentFailure: String?
    @State private var sendingTask: Task<Void, Never>?
    @State private var importCancellation = 0
    private var session: AgentConversation? { presentation.session }
    private var running: Bool { presentation.running }
    private var canSend: Bool {
        !running && !presentation.stopping && !importingAttachments && !sendingAttachments &&
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session?.draftAttachments?.isEmpty == false) && draft.count <= 2_000
    }
    var body: some View {
        Group {
            if let session {
                VStack(spacing: 0) {
                    if let navigation = presentation.activityNavigation {
                        Text(navigation.notice).font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 20).padding(.bottom, 8).accessibilityIdentifier("activityNavigationNotice")
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                if presentation.awaitingTaskConfirmation {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Label("Siri · 待确认", systemImage: "waveform").font(.headline)
                                        Text("请核对或编辑下方文本，再点“确认开始”。")
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
                                    .onScrollVisibilityChange(threshold: 0.01) { visible in
                                        lastMessageVisible = visible
                                        if userScrolling { followLatest = visible }
                                    }
                            }.padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: 780).frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("conversationMessages")
                        .accessibilityValue(viewportDiagnostic)
                        .scrollDismissesKeyboard(.interactively)
                        .simultaneousGesture(TapGesture().onEnded { focused = false })
                        .scrollEdgeEffectStyle(.soft, for: .bottom)
                        .defaultScrollAnchor(.bottom, for: .initialOffset)
                        .scrollPosition($scrollPosition, anchor: .top)
                        .onScrollPhaseChange { old, phase, context in
                            userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                            if phase == .idle && (old == .interacting || old == .decelerating) {
                                followLatest = lastMessageVisible || session.messages.isEmpty
                                if deferredViewportShift != 0 {
                                    let geometry = context.geometry
                                    scrollPosition.scrollTo(y: max(0, geometry.contentOffset.y + geometry.contentInsets.top + deferredViewportShift))
                                    deferredViewportShift = 0
                                }
                            }
                        }
                        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { old, new in
                            let shift = old.containerSize.height - new.containerSize.height
                            if ProcessInfo.processInfo.arguments.contains("--ui-test-composer-history") {
                                viewportDiagnostic = "offset=\(new.contentOffset.y) height=\(new.containerSize.height) bottomInset=\(new.contentInsets.bottom) topInset=\(new.contentInsets.top) shift=\(shift)"
                            }
                            if shift != 0 {
                                if userScrolling {
                                    deferredViewportShift += shift
                                } else if followLatest {
                                    proxy.scrollTo("latest", anchor: .bottom)
                                } else {
                                    scrollPosition.scrollTo(y: max(0, old.contentOffset.y + new.contentInsets.top + shift))
                                }
                            } else if followLatest && !userScrolling && old.contentSize != new.contentSize {
                                proxy.scrollTo("latest", anchor: .bottom)
                            }
                        }
                        .onChange(of: session.messages) { _, _ in if followLatest && !userScrolling { proxy.scrollTo("latest", anchor: .bottom) } }
                        .onChange(of: presentation.approvalID) { _, _ in if followLatest && !userScrolling { proxy.scrollTo("latest", anchor: .bottom) } }
                        .task {
                            guard presentation.activityNavigation == nil else { return }
                            followLatest = true
                            await Task.yield()
                            proxy.scrollTo("latest", anchor: .bottom)
                        }
                        .task(id: presentation.activityNavigation?.id) {
                            guard let navigation = presentation.activityNavigation, let target = navigation.messageID else { return }
                            followLatest = false
                            await Task.yield()
                            proxy.scrollTo(target, anchor: .center)
                        }

                    }
                }
                .safeAreaBar(edge: .bottom, spacing: 0) { composer }
                .navigationTitle(session.title).navigationBarTitleDisplayMode(.inline)
                .alert("选择模型", isPresented: $choosingModel) {
                    TextField("模型 ID", text: $customModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("使用") { presentation.selectModel(customModel.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    Button("取消", role: .cancel) {}
                } message: { Text("使用当前服务商的模型 ID。") }
                .sheet(isPresented: $browsingModels) {
                    if let profile = presentation.selectedProvider {
                        ProviderModelPicker(profile: profile) { presentation.selectModel($0) }
                    }
                }
                .onAppear { presentation.open(); draft = session.draft }
                .onDisappear { sendingTask?.cancel(); presentation.close() }
                .onChange(of: draft) { _, text in presentation.saveDraft(text) }
            } else { ContentUnavailableView("会话已删除", systemImage: "bubble.left") }
        }
        .environment(\.conversationDisclosureChanged, {
            followLatest = false
        })
    }
    private var modelPicker: some View {
        Menu {
            Section("服务商") {
                ForEach(presentation.providers) { provider in
                    Button { presentation.selectProvider(provider.id) } label: {
                        if provider.id == presentation.providerID { Label(provider.name, systemImage: "checkmark") }
                        else { Text(provider.name) }
                    }
                }
            }
            Section("模型") {
                ForEach(Array(presentation.availableModels.prefix(12)), id: \.self) { name in
                    Button { presentation.selectModel(name) } label: {
                        if name == presentation.selectedModel { Label(name, systemImage: "checkmark") }
                        else { Text(name) }
                    }
                }
                Button("浏览全部模型") { browsingModels = true }.disabled(presentation.providerID == nil)
                Button("其他模型…") { customModel = presentation.selectedModel; choosingModel = true }
                    .disabled(presentation.providerID == nil)
            }
            Button("管理服务商", action: openProviders)
        } label: {
            Label(presentation.modelName, systemImage: "chevron.down").lineLimit(1)
        }.menuOrder(.fixed).disabled(running || presentation.stopping).accessibilityIdentifier("conversationModelPicker")
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
            VStack(alignment: .trailing, spacing: 8) {
                HStack { Spacer(minLength: 36); Text(message.text).textSelection(.enabled).padding(12).background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 18)).foregroundStyle(.primary) }
                MessageAttachmentsView(message: message, presentation: presentation)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if let reasoning = message.reasoning, !reasoning.text.isEmpty {
                    ReasoningMessageView(reasoning: reasoning, messageID: message.id)
                }
                if !message.text.isEmpty {
                    Markdown(message.text).markdownTheme(.basic)
                        .markdownImageProvider(NoRemoteMarkdownImages()).markdownInlineImageProvider(NoRemoteInlineImages())
                        .textSelection(.enabled)
                } else if message.state == .streaming && message.reasoning == nil { Text("正在准备回复…").foregroundStyle(.secondary) }
                if message.state == .interrupted { Text("回复已中断").font(.caption).foregroundStyle(.secondary) }
                if message.state == .failed { Text("回复未完成").font(.caption).foregroundStyle(.secondary) }
                MessageAttachmentsView(message: message, presentation: presentation)
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
            if let attachmentFailure { Text(attachmentFailure).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("attachmentFailure") }
            if importingAttachments || sendingAttachments {
                HStack {
                    ProgressView(importingAttachments ? "正在复制附件到本机…" : "正在准备附件…")
                    Button("取消") { importCancellation += 1; sendingTask?.cancel() }
                }.font(.caption)
            }
            if let assets = session?.draftAttachments, !assets.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(assets) { asset in
                            VStack(alignment: .leading, spacing: 5) {
                                AttachmentThumbnail(attachment: asset, store: presentation.attachments, conversationID: presentation.sessionID)
                                    .frame(width: 100, height: 90).clipped()
                                Button("移除", systemImage: "xmark.circle") { presentation.removeAttachment(asset.id) }
                                    .font(.caption).disabled(running || sendingAttachments)
                                    .accessibilityIdentifier("removeAttachment-" + asset.id.uuidString)
                            }
                        }
                    }
                }.accessibilityIdentifier("draftAttachments")
                Text("发送后将图片及文本内容交给当前模型。支持单帧图片 ≤20 MiB、UTF-8 TXT/MD/JSON/CSV ≤256 KiB；暂不支持 PDF/Office。图片按最长边 2048 像素发送，原图保留本机。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 4) {
                    if !focused { attachmentButton }
                    messageField
                    if !focused { sendButton }
                }
                .padding(.leading, focused ? 10 : 4)
                .padding(.trailing, focused ? 10 : 9)
                if focused {
                    HStack(spacing: 8) {
                        attachmentButton
                        Spacer(minLength: 0)
                        if session?.mode != .demo { modelPicker.font(.caption).foregroundStyle(.secondary) }
                        sendButton
                    }.padding(.leading, 4).padding(.trailing, 8)
                }
            }.padding(.vertical, 6)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
    }
    private var attachmentButton: some View {
        AttachmentPicker(presentation: presentation, busy: $importingAttachments, failure: $attachmentFailure, cancellation: $importCancellation)
            .disabled(sendingAttachments)
    }
    private var messageField: some View {
        ZStack(alignment: .topLeading) {
            if draft.isEmpty {
                Text("随心输入").foregroundStyle(.tertiary).padding(.vertical, 10)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            MessageInput(text: $draft, focused: $focused, disabled: running || presentation.stopping || sendingAttachments, onSubmit: send)
        }
    }
    @ViewBuilder private var sendButton: some View {
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
    }
    @ViewBuilder private func toolPreview(_ item: ToolPresentation) -> some View {
        if !item.attachments.isEmpty, item.approval == nil {
            ForEach(item.attachments) { attachment in
                AttachmentThumbnail(attachment: attachment, store: presentation.attachments, conversationID: presentation.sessionID)
            }
        } else if let image = item.image, let uiImage = UIImage(data: image.png) {
            Image(uiImage: uiImage).resizable().scaledToFit().frame(maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel(image.isDemo ? "演示合成屏幕，不是真机截图" : "当前步骤的设备截图")
        } else if item.tool.name == "screenshot", item.tool.state == .succeeded {
            Text("此历史截图未保存本地原图，无法从工具记录恢复。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func send() {
        guard !presentation.awaitingTaskConfirmation else { return }
        sendConfirmedTask()
    }
    private func sendConfirmedTask() {
        guard canSend else { return }
        // The Send button and keyboard submission both authorize this request.
        if session?.draftAttachments?.isEmpty != false {
            if presentation.dispatch(.send(sessionID: presentation.sessionID, text: draft, cloudConsent: true)) {
                draft = ""; focused = false; followLatest = true
            }
            return
        }
        sendingAttachments = true; attachmentFailure = nil
        let text = draft
        sendingTask = Task { @MainActor in
            defer { sendingAttachments = false }
            do {
                if try await presentation.sendDraft(text) { draft = ""; focused = false; followLatest = true }
            } catch { if !Task.isCancelled { attachmentFailure = error.localizedDescription } }
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
    func makeImage(url: URL?) -> some View { Text("图片见下方").font(.caption).foregroundStyle(.secondary) }
}
private struct NoRemoteInlineImages: MarkdownUI.InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image { Image(systemName: "photo") }
}
