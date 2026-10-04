# Architecture and invariants

`SwiftUI -> AgentViewModel -> SwiftAgentKit Agent -> DeviceTool -> ActionCoordinator -> DeviceBridge`

DemoProvider + DemoBridge are entirely local and synthetic. PrivateVisionProvider + TLSBridge are the live path; live starts with a bridge screenshot preflight before a billed model request. Actual firmware support is still missing.

ActionCoordinator owns the current image, action count, time budget and mandatory approval. Coordinate input is validated before approval and the image is validated again afterward. The image is invalidated before a command send. Each input must therefore be followed by a fresh screenshot; finish also requires an observation. This local gate remains active regardless of the framework's autonomous-mode flag.

AgentViewModel owns UI generation fencing and cancellation. Stop has one idempotent teardown owner even across repeated inactive/background notifications; disconnect uses this same path. Stop immediately advances the generation, cancels the Task/provider, requests framework cancellation, resolves any pending approval false, stops both bridge layers and waits for the old task to drain before permitting a new run. Late results cannot repopulate the screen or complete a newer task. Listener startup is separately tracked, cancelled and drained, with foreground and generation checks before and after the actor hop. Listener failure and incoming-connection callbacks are bound to listener generation, so an old listener cannot tear down or admit peers into a newer listener. A resumed task keeps its task record ID but creates a new agent/context and obtains a fresh screenshot.

TLSBridge owns one listener, one authenticated peer, one in-flight command and exact correlation IDs. FramedConnection handles bytes with exact-length reads, bounded frames, timeouts and cancellation. ImageAssembler treats screenshots as uncommitted transactions until hash/size/PNG decode and final tool_result succeed. Nothing displays a partially received image.

The provider wrapper uses ephemeral URLSession, blocks all redirects, imposes a 4MiB response cap and short network timeouts, and drops separated reasoning/raw data. Because SwiftAgentKit retries generic provider failures by default, the wrapper maps its fail-closed errors to the framework's non-retryable invalidRequest category. No raw upstream error body is returned. Tool results use the verified LLMProviderKit tool-image expansion adapter. After each new image result the app removes prior image bytes from stored agent messages.

Local TaskStore persists only goal, mode, phase, bounded public receipts, result and reported token count. These can still contain user-sensitive task content; they remain protected in the app container and excluded from backup. Screenshots are memory-only. Keychain stores API keys by exact configured endpoint and the separate bridge PSK under a separate account. No session token, Apple pairing identity or background entitlement exists in the source.

Important limits: prompt-level safety text is not a reliable semantic classifier; coordinate taps cannot prove their business consequence. Mandatory user review and no automatic replay provide bounded control, not blanket production safety. The same-phone foreground limitation is architectural, not a networking fix.
