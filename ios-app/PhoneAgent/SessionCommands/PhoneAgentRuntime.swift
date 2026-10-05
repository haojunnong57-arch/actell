import Foundation

/// There is one app process, one conversation store, and one lifecycle-managed runner.
@MainActor final class PhoneAgentRuntime {
    static let shared = PhoneAgentRuntime()
    let model: AgentViewModel
    let commands: SessionCommandService
    private init() {
        model = Self.makeModel()
        commands = SessionCommandService(sessions: model.sessions, runner: model)
    }
    #if DEBUG
    private var invokedSiriFixture = false
    func invokeSiriFixtureIfNeeded(busy: Bool) async {
        let arguments = ProcessInfo.processInfo.arguments
        let flag = busy ? "--ui-test-siri-busy" : "--ui-test-siri-warm"
        guard arguments.contains("--ui-testing"), arguments.contains(flag), !invokedSiriFixture else { return }
        invokedSiriFixture = true
        let intent = PrepareAgentTaskIntent(); intent.task = "查看演示计数器"
        do { _ = try await intent.perform() }
        catch { model.errorMessage = error.localizedDescription }
    }
    #endif
    private static func makeModel() -> AgentViewModel {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") || ProcessInfo.processInfo.environment["PHONEAGENT_ISOLATED_TESTS"] == "1" {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--ui-test-images-seed") || arguments.contains("--ui-test-images-restore") {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneAgentImageUITest", isDirectory: true)
                if arguments.contains("--ui-test-images-seed") { try? FileManager.default.removeItem(at: directory) }
                let sessions = ConversationStore(directory: directory)
                if sessions.conversations.isEmpty { sessions.create(mode: .demo) }
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: DemoProvider(), bridge: DemoBridge()),
                    attachments: AttachmentStore(directory: directory.appendingPathComponent("assets")))
            }
            if arguments.contains("--ui-test-siri-seed") || arguments.contains("--ui-test-siri-restore") {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneAgentSiriUITest", isDirectory: true)
                if arguments.contains("--ui-test-siri-seed") { try? FileManager.default.removeItem(at: directory) }
                let sessions = ConversationStore(directory: directory)
                if arguments.contains("--ui-test-siri-seed") {
                    _ = try? sessions.prepare(SessionCommand(.prepare("查看演示计数器")), task: "查看演示计数器")
                }
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: DemoProvider(), bridge: DemoBridge()))
            }
            let sessions = ConversationStore(inMemory: true)
            if arguments.contains("--ui-test-model-catalog") {
                let model = AgentViewModel(sessions: sessions, loadPersistentState: false)
                try? model.providers.save(ProviderProfile(name: "Catalog Fixture", settings: .init(baseURL: "https://catalog-fixture.invalid/v1", model: "")))
                return model
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--ui-test-tool-error") {
                sessions.create(mode: .live)
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: ToolErrorFixtureProvider(), bridge: UnavailableBridge()))
            }
            // Existing demo history keeps UI regression tests offline without
            // exposing a demo-creation route in the production conversation UI.
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
               (arguments.contains("--ui-test-demo-history") || arguments.contains("--ui-test-siri-busy")) {
                sessions.create(mode: .demo)
            }
            if arguments.contains("--ui-test-siri-warm") || arguments.contains("--ui-test-siri-busy") {
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: DemoProvider(), bridge: DemoBridge()))
            }
            return AgentViewModel(sessions: sessions, loadPersistentState: false,
                liveActivitiesEnabled: arguments.contains("--ui-test-live-activity"))
        }
        #endif
        return AgentViewModel()
    }
}
