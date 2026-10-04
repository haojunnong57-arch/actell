import AppIntents

struct PrepareAgentTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Create a task"
    static let description = IntentDescription("Save a task draft and open PhoneAgent for confirmation. This does not start the agent.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static var openAppWhenRun: Bool { true } // iOS 17–25
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .foreground(.immediate) }
    @available(iOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Task", requestValueDialog: "What would you like PhoneAgent to do?")
    var task: String

    static var parameterSummary: some ParameterSummary { Summary("Create a task: \(\.$task)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try Task.checkCancellation()
        let service = PhoneAgentRuntime.shared.commands
        _ = try service.perform(SessionCommand(.prepare(task)))
        // No await between cancellation validation and atomic persistence. A
        // cancellation after this point may leave a draft, never a running task.
        return .result(dialog: "Draft saved. Review it in PhoneAgent and tap Confirm and start. If another task is active, this draft will wait.")
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
    static let description = IntentDescription("Stop the current run through PhoneAgent. Actions already sent may have happened.")
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
        AppShortcut(intent: PrepareAgentTaskIntent(), phrases: ["Create a task with \(.applicationName)"],
                    shortTitle: "Create a task", systemImageName: "square.and.pencil")
        AppShortcut(intent: AgentTaskStatusIntent(), phrases: ["Check task status in \(.applicationName)"],
                    shortTitle: "Task status", systemImageName: "checklist")
        AppShortcut(intent: StopAgentTaskIntent(), phrases: ["Stop the current task in \(.applicationName)"],
                    shortTitle: "Stop task", systemImageName: "stop.circle")
    }
}
