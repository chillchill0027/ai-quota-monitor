// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AIQuotaMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AIQuotaMonitor", targets: ["AIQuotaMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "AIQuotaMonitor",
            path: "Sources"
        )
    ]
)
