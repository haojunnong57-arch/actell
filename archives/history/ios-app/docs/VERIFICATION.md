# Verification record · 2026-10-02 UTC

This record distinguishes implementation, source-level checks and runtime evidence. It is not a release certification.

## Passed in the dot cloud Linux workspace

- Upstream source inspection at actual git revisions: SwiftAgentKit 84ddf324fd2a223834323537eb3f8746d669753b; LLMProviderKit f55aeb4d7a935b9f20c5c85d32cd21eb635ee38d (tag 0.1.0-alpha.35)
- Agent/AgentConfig/AgentTool/AgentToolResult/images/callbacks/cancellation APIs matched against the inspected source
- OpenAI provider source confirms image-bearing tool messages are expanded into a text-only tool result followed by an adjacent user image message; app wrapper uses this adapter and keeps only latest image
- Apple official TLS-PSK sample inspected for the public `sec_protocol_options_add_pre_shared_key` / TLS_PSK_WITH_AES_128_GCM_SHA256 pattern; TN3213 verifies TLS1.2 + legacy NW API limitation
- 12 independent Python wire-contract tests passed. These validate fixtures/reference code, **not the Swift implementation**
- tree-sitter-swift 0.7.3 parsed 15 Swift source/test files with no grammar errors. Grammar acceptance does not establish type correctness or SDK availability
- YAML/plist parsing, direct dependency assertions, foreground-only flags, deny-redirect/no-raw-logging/cancel/mandatory-approval source assertions passed
- Independent read-only review matched pinned Agent/Provider APIs and found two listener lifecycle races; source now tracks/cancels pending startup and fences listener callbacks by generation. Static recheck is separate from unrun runtime tests
- ZIP archive CRC and secret/cache exclusion checked at packaging

## Written but never run

13 XCTest tests: framing/bounds, envelope round trip, inclusive normalized coordinates, transactional-image guards, chunk ordering/size, hash/ID errors, provider URL restrictions, denied action, new screenshot after input, stop fence, finish observation requirement, Boolean-coordinate rejection, provider image-message shape.

## Blocked / outstanding

- No Swift binary, Xcode, xcodebuild, XcodeGen or iOS SDK in this Linux environment. No Swift type-check, SPM solve, generated Xcode project, app compile/link/signing, simulator launch, screenshot of actual SwiftUI, or XCTest results
- Third-party alpha package resolver / SwiftSyntax compiler compatibility requires the first actual Xcode build. Direct dependencies are pinned; transitive resolution is not claimed
- No cloud API calls made. Model capabilities, parameter acceptance, usage reporting and charges untested
- No physical ESP32/iPhone attached. Firmware v0.3 does not implement the App channel. No real PSK handshake, plaintext-rejection test, usbmux port routing, chunked PNG flow, touch mapping, input effects or post-stop socket behavior established
- No background execution claim. Backgrounding intentionally stops the app; sustained same-phone cross-app operation is not provided
- Privacy manifest and App Store distribution declarations require an app-specific review before distribution, especially with user-selected external API providers

## Manual test order after Mac/device authorization

1. Resolve/build pinned source; record actual Xcode/Swift versions and commit a real generated Package.resolved
2. Run all XCTest; run offline demo. Approve once, reject once, Stop during screenshot/provider/approval, double-tap Start, re-enter settings and restart a stopped task
3. Background / lock phone during approval and transfer. Check canceled requests, no stale approval after returning, no replay on resume, same task ID retained
4. Verify key entry stays SecureField/Keychain, change endpoint cannot reuse old endpoint key, redirects cannot move Authorization, raw model errors and images absent from disk/logs
5. TLS peer with correct/incorrect/random PSK and plaintext; first ensure failures do not enable live state. Supply backend_ready:false and unsupported capabilities
6. Wire corruption/disconnect/timeout/wrong ID tests against actual Swift parser. No partial image may reach UI or model
7. Real CoreDevice PNG through ESP32, orientation/dimensions, approved harmless touch and verification PNG. Input loss must produce unknown outcome and no retry
8. Only then describe any successful live path, with the exact device/OS/firmware/App versions and source commit. Never infer cross-app background continuity from an isolated screenshot or touch
