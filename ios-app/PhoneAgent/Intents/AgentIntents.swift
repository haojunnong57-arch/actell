import AppIntents

struct PrepareAgentTaskIntent: AppIntent, TargetContentProvidingIntent {
    var contentIdentifier: String { "execute-task" }
    static let title: LocalizedStringResource = "Execute a task"
    static let description = IntentDescription("Open Zhiyan and immediately execute the supplied task.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var openAppWhenRun: Bool { true } // iOS 17–25
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .foreground(.immediate) }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Task", requestValueDialog: "What would you like Zhiyan to do?")
    var task: String

    static var parameterSummary: some ParameterSummary { Summary("Execute a task: \(\.$task)") }

    @MainActor func perform() async throws -> some IntentResult {
        try Task.checkCancellation()
        let service = PhoneAgentRuntime.shared.commands
        PhoneAgentRuntime.shared.model.usbDiagnostics.record("siri.execute received=true ready=\(PhoneAgentRuntime.shared.model.commandCanStart)")
        let command = SessionCommand(.execute(task))
        do {
            _ = try service.perform(command)
        } catch {
            let model = PhoneAgentRuntime.shared.model
            model.errorMessage = error.localizedDescription
            model.usbDiagnostics.record("siri.execute failed=\(error.localizedDescription)")
            if let session = service.sessions.conversations.first(where: { $0.entry?.commandID == command.commandID }) {
                service.sessions.addNotice(error.localizedDescription, in: session.id)
            }
        }
        return .result()
    }
}

struct AgentTaskStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check task status"
    static let description = IntentDescription("Read only a general task state, without task text or results.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try Task.checkCancellation()
        guard case .status(let status) = try PhoneAgentRuntime.shared.commands.perform(SessionCommand(.status)) else {
            return .result(dialog: "No task is currently running.")
        }
        return .result(dialog: IntentDialog(stringLiteral: status.message))
    }
}

struct StopAgentTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop the current task"
    static let description = IntentDescription("Stop the current run through Zhiyan. Actions already sent may have happened.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try Task.checkCancellation()
        let service = PhoneAgentRuntime.shared.commands
        let command = service.cancelCurrentCommand()
        if try service.perform(command) == .cancelled {
            return .result(dialog: "Stop requested. Actions already sent may have happened; check your device.")
        }
        return .result(dialog: "No matching task is currently running.")
    }
}

struct PhoneAgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PrepareAgentTaskIntent(), phrases: ["Execute a task with \(.applicationName)", "Execute a task in \(.applicationName)"],
                    shortTitle: "Execute a task", systemImageName: "square.and.pencil")
        AppShortcut(intent: AgentTaskStatusIntent(), phrases: ["Check task status in \(.applicationName)"],
                    shortTitle: "Task status", systemImageName: "checklist")
        AppShortcut(intent: StopAgentTaskIntent(), phrases: ["Stop the current task in \(.applicationName)"],
                    shortTitle: "Stop task", systemImageName: "stop.circle")
    }
}
