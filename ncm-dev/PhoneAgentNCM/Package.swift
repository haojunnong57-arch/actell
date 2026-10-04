// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PhoneAgentNCM", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "PhoneAgentNCM", targets: ["PhoneAgentNCM"])],
    targets: [.target(name: "PhoneAgentNCM"), .testTarget(name: "PhoneAgentNCMTests", dependencies: ["PhoneAgentNCM"])])
