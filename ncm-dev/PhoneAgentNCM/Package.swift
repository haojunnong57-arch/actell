// swift-tools-version: 5.9
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let archive = ProcessInfo.processInfo.environment["NCM_BACKEND_ARCHIVE_DIR"] ?? root.appendingPathComponent(".build/ncm-rust/aarch64-apple-darwin/release").path
let fixtures = ProcessInfo.processInfo.environment["NCM_OFFLINE_FIXTURES"] == "1"
let package = Package(name: "PhoneAgentNCM", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "PhoneAgentNCM", targets: ["PhoneAgentNCM"])],
    targets: [
        .target(name: "CNCMBackend", publicHeadersPath: "include", cSettings: fixtures ? [.define("NCM_OFFLINE_FIXTURES")] : [], linkerSettings: [.unsafeFlags(["-L", archive]), .linkedLibrary("phoneagent_ncm_backend"), .linkedFramework("Security"), .linkedFramework("SystemConfiguration")]),
        .target(name: "PhoneAgentNCM", dependencies: ["CNCMBackend"], swiftSettings: fixtures ? [.define("NCM_OFFLINE_FIXTURES"), .unsafeFlags(["-Xcc", "-DNCM_OFFLINE_FIXTURES"])] : []),
        .testTarget(name: "PhoneAgentNCMTests", dependencies: ["PhoneAgentNCM", "CNCMBackend"], swiftSettings: fixtures ? [.define("NCM_OFFLINE_FIXTURES"), .unsafeFlags(["-Xcc", "-DNCM_OFFLINE_FIXTURES"])] : [])])
