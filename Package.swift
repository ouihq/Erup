// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScooterProtocol",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ScooterProtocol", targets: ["ScooterProtocol"]),
        .library(name: "ScooterAnalytics", targets: ["ScooterAnalytics"]),
    ],
    targets: [
        .target(name: "ScooterProtocol"),
        .testTarget(name: "ScooterProtocolTests", dependencies: ["ScooterProtocol"]),
        .target(name: "ScooterAnalytics"),
        .testTarget(name: "ScooterAnalyticsTests", dependencies: ["ScooterAnalytics"]),
    ]
)
