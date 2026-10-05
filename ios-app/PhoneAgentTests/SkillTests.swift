import XCTest
import SwiftAgentKit
import LLMProviderKit
@testable import PhoneAgent

@MainActor final class SkillTests: XCTestCase {
    private let document = "---\nname: Synthetic Guide\ndescription: Read synthetic fixtures\nversion: 1\n---\nBODY_NOT_A_SUMMARY\nSee [reference](references/guide.md)."
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testImportVersionsDuplicateDisableDeleteAndRestart() throws {
        let root = try directory(), store = SkillStore(directory: root)
        let first = try store.add(documents: ["SKILL.md": document])
        XCTAssertEqual(try store.add(documents: ["SKILL.md": document]).id, first.id)
        let next = try store.add(documents: ["SKILL.md": document + "\nUpdated"])
        XCTAssertNotEqual(first.id, next.id); XCTAssertNotEqual(first.revision, next.revision)
        try store.setEnabled(false, id: first.id)
        XCTAssertEqual(store.enabledSnapshot.map(\.id), [next.id])
        let restored = SkillStore(directory: root)
        XCTAssertEqual(restored.packages, store.packages)
        try restored.remove(next.id); XCTAssertEqual(restored.packages.count, 1)
        XCTAssertTrue(restored.enabledSnapshot.isEmpty)
    }
    func testNativePackageCopyRetainsReferencesAndRejectsScriptsSymlinksAndBadPaths() throws {
        let root = try directory(), bundle = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("references"), withIntermediateDirectories: true)
        try Data(document.utf8).write(to: bundle.appendingPathComponent("SKILL.md"))
        try Data("REFERENCE_BODY".utf8).write(to: bundle.appendingPathComponent("references/guide.md"))
        let store = SkillStore(inMemory: true), imported = try store.importPackage(bundle)
        XCTAssertEqual(imported.documents["references/guide.md"], "REFERENCE_BODY")
        try Data("echo must-not-run".utf8).write(to: bundle.appendingPathComponent("run.sh"))
        XCTAssertThrowsError(try store.importPackage(bundle))
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("run.sh"))
        try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("outside.md"), withDestinationURL: root.appendingPathComponent("private.md"))
        XCTAssertThrowsError(try store.importPackage(bundle))
        for path in ["../escape.md", "/tmp/private.md", "refs/../../secret.md", "refs\\private.md", "https://x/file.md", "refs//x.md"] {
            XCTAssertThrowsError(try store.add(documents: ["SKILL.md": document, path: "invalid"]))
        }
        XCTAssertEqual(store.packages.count, 1)
    }
    func testMetadataFormatLimitsAndCorruptArchivePreserveOriginal() throws {
        let store = SkillStore(inMemory: true)
        for body in ["# No metadata", "---\nname: x\n---\nmissing description", "---\nname: x\nname: y\ndescription: d\n---", String(repeating: "a", count: 64 * 1024 + 1)] {
            XCTAssertThrowsError(try store.add(documents: ["SKILL.md": body]))
        }
        let multi = try store.add(documents: ["SKILL.md": "---\nname: 'multi'\ndescription: >\n  first line\n  second line\n---\nBody"])
        XCTAssertEqual(multi.summary, "first line second line")
        let root = try directory(), file = root.appendingPathComponent("skills-v1.json"), bytes = Data("unreadable".utf8)
        try bytes.write(to: file)
        let broken = SkillStore(directory: root)
        XCTAssertNotNil(broken.warning); XCTAssertThrowsError(try broken.add(documents: ["SKILL.md": document]))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testCatalogOnlyLoadsChosenVersionAndResourceWithoutDumpingBodyInSearch() throws {
        let store = SkillStore(inMemory: true)
        let item = try store.add(documents: ["SKILL.md": document, "references/guide.md": "REFERENCE_BODY"])
        let catalog = SkillCatalog(packages: store.enabledSnapshot)
        for name in ["list_skills", "search_skills"] {
            let result = try catalog.result(name: name, parameters: name == "list_skills" ? [:] : ["query": "synthetic"])
            XCTAssertTrue(result.contains(item.name)); XCTAssertFalse(result.contains("BODY_NOT_A_SUMMARY")); XCTAssertFalse(result.contains("REFERENCE_BODY"))
        }
        let arguments = ["id": item.id.uuidString, "revision": item.revision]
        XCTAssertTrue(try catalog.result(name: "load_skill", parameters: arguments).contains("BODY_NOT_A_SUMMARY"))
        XCTAssertFalse(try catalog.result(name: "load_skill", parameters: arguments).contains("REFERENCE_BODY"))
        XCTAssertTrue(try catalog.result(name: "load_skill", parameters: arguments.merging(["resource": "references/guide.md"]) { _, b in b }).contains("REFERENCE_BODY"))
        for extra in [["revision": "wrong"], ["id": UUID().uuidString], ["resource": "../private.md"], ["resource": "missing.md"]] {
            XCTAssertThrowsError(try catalog.result(name: "load_skill", parameters: arguments.merging(extra) { _, b in b }))
        }
        try store.setEnabled(false, id: item.id)
        XCTAssertThrowsError(try SkillCatalog(packages: store.enabledSnapshot).result(name: "load_skill", parameters: arguments))
        XCTAssertTrue(try catalog.result(name: "load_skill", parameters: arguments).contains("BODY_NOT_A_SUMMARY")) // frozen old run
    }
    func testCancelledImportAndStaleToolContextNeverRead() async throws {
        let store = SkillStore(inMemory: true), body = document
        let task = Task { try store.add(documents: ["SKILL.md": body]) }; task.cancel()
        do { _ = try await task.value; XCTFail() } catch {}
        XCTAssertTrue(store.packages.isEmpty)
        let item = try store.add(documents: ["SKILL.md": body])
        let tool = SkillTool(name: "load_skill", catalog: SkillCatalog(packages: [item]), canRead: { false })
        let context = ToolContext(callId: "stale", toolName: "load_skill", parameters: ["id": item.id.uuidString, "revision": item.revision], state: AgentState())
        do { _ = try await tool.execute(context: context); XCTFail() } catch { XCTAssertEqual(error as? AppError, .stopped) }
    }
    func testLongSkillCanBeReadExactlyThroughVersionedPages() throws {
        let body = document + String(repeating: "资料🙂\n", count: 1_500)
        let item = try SkillPackage.make(documents: ["SKILL.md": body]), catalog = SkillCatalog(packages: [item])
        var offset = 0, restored = ""
        while true {
            let response = try catalog.result(name: "load_skill", parameters: ["id": item.id.uuidString, "revision": item.revision, "offset": offset])
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
            let page = try XCTUnwrap(object["content"] as? String)
            XCTAssertLessThanOrEqual(page.count, 2_000); restored += page
            guard let next = object["next_offset"] as? Int else { break }
            XCTAssertGreaterThan(next, offset); offset = next
        }
        XCTAssertEqual(restored, body)
        for invalid in [-1, true, 0.5, body.count + 1] as [Any] {
            XCTAssertThrowsError(try catalog.result(name: "load_skill", parameters: ["id": item.id.uuidString, "revision": item.revision, "offset": invalid]))
        }
    }
    func testActualAgentDiscoversAndLoadsSkillReferenceAndProjectsNamedIcon() async throws {
        let store = SkillStore(inMemory: true)
        _ = try store.add(documents: ["SKILL.md": document, "references/guide.md": "REFERENCE_BODY"])
        let provider = SkillRoundTripProvider()
        let model = AgentViewModel(sessions: ConversationStore(inMemory: true), loadPersistentState: false,
            runServices: AgentRunServices(provider: provider, bridge: UnavailableBridge()), skills: store)
        let id = model.createConversation(mode: .live)
        XCTAssertTrue(model.send("Use the synthetic guide", in: id, cloudConsent: true))
        for _ in 0..<150 where model.running { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.sessions.conversation(id)?.phase, .completed)
        let tools = model.sessions.conversation(id)?.messages.compactMap(\.tool) ?? []
        XCTAssertEqual(tools.map(\.name), ["list_skills", "search_skills", "load_skill", "load_skill"])
        XCTAssertTrue(tools.allSatisfy { $0.state == .succeeded })
        XCTAssertEqual(tools.last?.skillName, "Synthetic Guide")
        XCTAssertEqual(tools.last?.symbol, "book.closed")
        XCTAssertFalse(tools.contains { $0.result.contains("BODY_NOT_A_SUMMARY") || $0.result.contains("REFERENCE_BODY") })
    }
}

private struct SkillRoundTripProvider: LLMProvider {
    static let name = "skill-roundtrip-fixture"
    let configuration = LLMProviderConfiguration(name: name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            do {
                let response = try respond(request)
                for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                continuation.yield(.finish(reason: response.finishReason, usage: nil)); continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
    func complete(_ request: LLMRequest) async throws -> LLMResponse { try respond(request) }
    private func respond(_ request: LLMRequest) throws -> LLMResponse {
        XCTAssertFalse(request.messages.filter { $0.role == .system }.contains { $0.content.contains("BODY_NOT_A_SUMMARY") })
        let results = request.messages.filter { $0.role == .tool }, stage = results.count
        let name: String, arguments: [String: String]
        if stage == 0 { name = "list_skills"; arguments = [:] }
        else if stage == 1 { name = "search_skills"; arguments = ["query": "synthetic"] }
        else if stage < 4 {
            let text = results[0].content, start = try XCTUnwrap(text.firstIndex(of: "{"))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: Any])
            let skill = try XCTUnwrap((object["skills"] as? [[String: String]])?.first)
            name = "load_skill"; arguments = ["id": skill["id"]!, "revision": skill["revision"]!, "resource": stage == 2 ? "SKILL.md" : "references/guide.md"]
        } else {
            XCTAssertTrue(results.contains { $0.content.contains("BODY_NOT_A_SUMMARY") })
            XCTAssertTrue(results.contains { $0.content.contains("REFERENCE_BODY") })
            return LLMResponse(text: "合成技能与参考已读取。", finishReason: .stop, request: request, providerName: Self.name)
        }
        return LLMResponse(text: "", finishReason: .toolCalls, toolCalls: [.init(id: "skill-\(stage)", name: name,
            arguments: String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self))], request: request, providerName: Self.name)
    }
}
