// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GitLabPipelineMonitor",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "GitLabPipelineMonitor",
            path: "Sources/GitLabPipelineMonitor"
        )
    ]
)
