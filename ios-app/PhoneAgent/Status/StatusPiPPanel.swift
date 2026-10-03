import SwiftUI
import AVFoundation
import UIKit

struct StatusPiPPanel: View {
    @ObservedObject var model: AgentViewModel
    @ObservedObject var controller: StatusPiPController
    private var snapshot: AgentStatusSnapshot {
        .make(mode: model.mode, phase: model.activeRecord?.phase, running: model.running, awaitingApproval: model.approval != nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("预览最小状态卡片", isOn: Binding(get: { controller.previewEnabled }, set: { controller.setPreviewEnabled($0) }))
            if controller.previewEnabled {
                StatusSampleBufferView(displayLayer: controller.displayLayer)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("\(snapshot.title)，\(snapshot.phase.rawValue)，\(snapshot.detail)")
                HStack {
                    Button { controller.start() } label: { Label("开启画中画（实验）", systemImage: "pip.enter") }
                        .disabled(!controller.supported || !controller.backgroundModeConfigured || controller.active)
                    if controller.active { Button("关闭画中画") { controller.stop() } }
                }.buttonStyle(.bordered)
                Text(controller.message).font(.caption).foregroundStyle(.secondary)
                Text("只显示任务类别、阶段和需确认状态；隐藏任务正文、截图和密钥。画中画不能确认动作，离开前台仍会停止 agent。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: snapshot, initial: true) { _, next in controller.update(next) }
    }
}

private struct StatusSampleBufferView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    func makeUIView(context: Context) -> StatusLayerView { StatusLayerView(displayLayer: displayLayer) }
    func updateUIView(_ view: StatusLayerView, context: Context) { view.setNeedsLayout() }
}
private final class StatusLayerView: UIView {
    private let displayLayer: AVSampleBufferDisplayLayer
    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        layer.addSublayer(displayLayer)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}
