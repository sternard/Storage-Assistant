// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "StorageAssistant",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "StorageAssistantCore",
            targets: ["StorageAssistantCore"]
        ),
        .executable(
            name: "storage-assistant",
            targets: ["StorageAssistantCLI"]
        ),
        .executable(
            name: "StorageAssistantApp",
            targets: ["StorageAssistantApp"]
        )
    ],
    targets: [
        .target(
            name: "StorageAssistantCore"
        ),
        .executableTarget(
            name: "StorageAssistantCLI",
            dependencies: ["StorageAssistantCore"]
        ),
        .executableTarget(
            name: "StorageAssistantApp",
            dependencies: ["StorageAssistantCore"]
        ),
        .testTarget(
            name: "StorageAssistantCoreTests",
            dependencies: ["StorageAssistantCore"]
        )
    ]
)
