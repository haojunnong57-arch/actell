import SwiftUI

struct AttachmentThumbnail: View {
    let attachment: StoredAttachment
    let store: AttachmentStore
    let conversationID: UUID
    @State private var preview: Data?
    @State private var failure: String?
    @State private var showingOriginal = false
    var body: some View {
        Button { showingOriginal = true } label: {
            VStack(alignment: .leading, spacing: 5) {
                if let preview, attachment.kind == .image, let image = UIImage(data: preview) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else { Image(systemName: attachment.kind == .image ? "photo" : "doc.text").font(.title2).frame(minHeight: 35) }
                Text(attachment.name).font(.caption).lineLimit(1)
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            }
        }
        .buttonStyle(.plain).accessibilityLabel("预览附件：" + attachment.name)
        .accessibilityIdentifier("attachment-" + attachment.id.uuidString)
        .task(id: attachment.id) {
            do { preview = try await store.preview(attachment, conversationID: conversationID); failure = nil }
            catch { failure = "本地文件暂不可用" }
        }
        .sheet(isPresented: $showingOriginal) { AttachmentPreview(attachment: attachment, store: store, conversationID: conversationID) }
    }
}

private struct AttachmentPreview: View {
    let attachment: StoredAttachment
    let store: AttachmentStore
    let conversationID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var data: Data?
    @State private var failure: String?
    @State private var scale: CGFloat = 1
    var body: some View {
        NavigationStack {
            Group {
                if let data, attachment.kind == .image, let image = UIImage(data: data) {
                    GeometryReader { geometry in
                        ScrollView([.horizontal, .vertical]) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(width: max(1, geometry.size.width - 32) * scale)
                                .accessibilityLabel("本地原图")
                        }
                        .gesture(MagnifyGesture().onEnded { scale = min(6, max(1, scale * $0.magnification)) })
                    }
                } else if let data, let text = String(data: data, encoding: .utf8) {
                    ScrollView { Text(text).font(.body.monospaced()).textSelection(.enabled).padding() }
                } else if let failure { ContentUnavailableView("无法读取附件", systemImage: "exclamationmark.triangle", description: Text(failure)) }
                else { ProgressView() }
            }
            .navigationTitle(attachment.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .task {
                do { data = try await store.read(attachment, conversationID: conversationID) }
                catch { failure = "本地文件丢失或暂不可访问；远程来源可回到消息重试，其他附件请重新选择。" }
            }
        }
    }
}

struct MessageAttachmentsView: View {
    let message: ChatMessage
    @ObservedObject var presentation: AgentPresentationAdapter
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach((message.attachments ?? []).filter { $0.sourceURL == nil }) { attachment in
                AttachmentThumbnail(attachment: attachment, store: presentation.attachments, conversationID: presentation.sessionID)
            }
            ForEach(Array(NSOrderedSet(array: MessageImageSources.urls(in: message.text))) as? [URL] ?? [], id: \.self) { url in
                RemoteMessageImage(url: url, message: message, presentation: presentation)
            }
        }
    }
}

private struct RemoteMessageImage: View {
    let url: URL
    let message: ChatMessage
    @ObservedObject var presentation: AgentPresentationAdapter
    @State private var loading = false
    @State private var failure: String?
    @State private var task: Task<Void, Never>?
    @State private var cacheAvailable = false
    private var cached: StoredAttachment? { message.attachments?.first { $0.sourceURL == url } }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cached, cacheAvailable {
                AttachmentThumbnail(attachment: cached, store: presentation.attachments, conversationID: presentation.sessionID)
            } else {
                Label("消息图片", systemImage: "photo")
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button(failure == nil ? "下载并缓存图片" : "重试原图源") { load() }.disabled(loading)
                    if loading {
                        ProgressView()
                        Button("取消") { task?.cancel(); loading = false }
                    }
                }
                Text("只请求此消息已有的图源，不发送服务商密钥；缓存成功后可离线查看。").font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityIdentifier("messageRemoteImage")
        .task(id: cached?.id) {
            if let cached { cacheAvailable = (try? await presentation.attachments.read(cached, conversationID: presentation.sessionID)) != nil }
        }
        .onDisappear { task?.cancel() }
    }
    private func load() {
        guard !loading else { return }
        loading = true; failure = nil
        task = Task { @MainActor in
            defer { loading = false }
            do { _ = try await presentation.cacheImage(url, messageID: message.id); cacheAvailable = true }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}
