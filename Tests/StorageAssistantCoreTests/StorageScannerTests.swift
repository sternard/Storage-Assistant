import Foundation
import StorageAssistantCore
import XCTest

final class StorageScannerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageAssistantTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testUsesConfiguredDeveloperRootsForUnityProjects() throws {
        let externalProjects = temporaryRoot.appendingPathComponent("ExternalProjects", isDirectory: true)
        let project = externalProjects.appendingPathComponent("TinyGame", isDirectory: true)
        try createUnityProject(at: project)
        try writeFile(
            at: project.appendingPathComponent("Library/Artifact.bin"),
            byteCount: 4_096
        )

        var config = tinyConfig()
        config.developerSearchRoots = [externalProjects]

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: config
        ).scan()

        let unityLibrary = result.recommendations.first {
            $0.category == .unity && $0.path.hasSuffix("TinyGame/Library")
        }

        XCTAssertNotNil(unityLibrary)
        XCTAssertEqual(unityLibrary?.risk, .medium)
        XCTAssertEqual(unityLibrary?.confidence, .high)
    }

    func testKeepsSpecificRecommendationWhenGenericCacheOverlaps() throws {
        let pipCache = temporaryRoot.appendingPathComponent("Library/Caches/pip", isDirectory: true)
        try writeFile(
            at: pipCache.appendingPathComponent("wheel-cache.bin"),
            byteCount: 4_096
        )

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: tinyConfig()
        ).scan()

        let pipRecommendations = result.recommendations.filter {
            samePath($0.path, pipCache.path)
        }

        XCTAssertEqual(pipRecommendations.count, 1)
        XCTAssertEqual(pipRecommendations.first?.category, .python)
    }

    func testDownloadDiskImagesAreReviewableAndTrashable() throws {
        let download = temporaryRoot.appendingPathComponent("Downloads/OldInstaller.dmg")
        try writeFile(at: download, byteCount: 4_096)

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: tinyConfig()
        ).scan()

        let recommendation = try XCTUnwrap(
            result.recommendations.first { samePath($0.path, download.path) }
        )

        XCTAssertEqual(recommendation.category, .downloads)
        XCTAssertEqual(recommendation.risk, .medium)
        XCTAssertEqual(recommendation.defaultAction, .moveToTrash)
    }

    func testFlagsSavedStateForUninstalledApp() throws {
        let savedState = temporaryRoot
            .appendingPathComponent("Library/Saved Application State/com.example.Missing.savedState", isDirectory: true)
        try writeFile(at: savedState.appendingPathComponent("state.bin"), byteCount: 4_096)

        var config = tinyConfig()
        config.enableAppLeftoverScan = true
        config.installedAppSearchRoots = [temporaryRoot.appendingPathComponent("Applications", isDirectory: true)]

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: config
        ).scan()

        let recommendation = try XCTUnwrap(
            result.recommendations.first {
                samePath($0.path, savedState.path) && $0.category == .leftovers
            }
        )

        XCTAssertEqual(recommendation.risk, .low)
        XCTAssertEqual(recommendation.defaultAction, .moveToTrash)
    }

    func testDoesNotFlagLeftoverForInstalledBundleIdentifier() throws {
        let app = temporaryRoot.appendingPathComponent("Applications/Installed.app", isDirectory: true)
        try createAppBundle(
            at: app,
            bundleIdentifier: "com.example.Installed",
            name: "Installed"
        )

        let savedState = temporaryRoot
            .appendingPathComponent("Library/Saved Application State/com.example.Installed.savedState", isDirectory: true)
        try writeFile(at: savedState.appendingPathComponent("state.bin"), byteCount: 4_096)

        var config = tinyConfig()
        config.enableAppLeftoverScan = true
        config.installedAppSearchRoots = [temporaryRoot.appendingPathComponent("Applications", isDirectory: true)]

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: config
        ).scan()

        XCTAssertFalse(
            result.recommendations.contains {
                samePath($0.path, savedState.path) && $0.category == .leftovers
            }
        )
    }

    func testFlagsAppContainerForUninstalledApp() throws {
        let container = temporaryRoot
            .appendingPathComponent("Library/Containers/com.example.Gone", isDirectory: true)
        try writeFile(at: container.appendingPathComponent("Data/state.db"), byteCount: 4_096)

        var config = tinyConfig()
        config.enableAppLeftoverScan = true
        config.installedAppSearchRoots = [temporaryRoot.appendingPathComponent("Applications", isDirectory: true)]

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: config
        ).scan()

        let recommendation = try XCTUnwrap(
            result.recommendations.first {
                samePath($0.path, container.path) && $0.category == .leftovers
            }
        )

        XCTAssertEqual(recommendation.confidence, .medium)
        XCTAssertEqual(recommendation.defaultAction, .revealOnly)
    }

    func testDoesNotFlagAppContainerForInstalledBundleIdentifier() throws {
        let app = temporaryRoot.appendingPathComponent("Applications/Installed.app", isDirectory: true)
        try createAppBundle(
            at: app,
            bundleIdentifier: "com.example.Installed",
            name: "Installed"
        )

        let container = temporaryRoot
            .appendingPathComponent("Library/Containers/com.example.Installed", isDirectory: true)
        try writeFile(at: container.appendingPathComponent("Data/state.db"), byteCount: 4_096)

        var config = tinyConfig()
        config.enableAppLeftoverScan = true
        config.installedAppSearchRoots = [temporaryRoot.appendingPathComponent("Applications", isDirectory: true)]

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: config
        ).scan()

        XCTAssertFalse(
            result.recommendations.contains {
                samePath($0.path, container.path) && $0.category == .leftovers
            }
        )
    }

    func testFlagsByHostPreferenceForUninstalledApp() throws {
        let preference = temporaryRoot
            .appendingPathComponent("Library/Preferences/ByHost/com.example.Gone.A1B2C3D4-E5F6.plist")
        try writeFile(at: preference, byteCount: 4_096)

        var config = tinyConfig()
        config.enableAppLeftoverScan = true
        config.installedAppSearchRoots = [temporaryRoot.appendingPathComponent("Applications", isDirectory: true)]

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: config
        ).scan()

        let recommendation = try XCTUnwrap(
            result.recommendations.first {
                samePath($0.path, preference.path) && $0.category == .leftovers
            }
        )

        XCTAssertEqual(recommendation.confidence, .medium)
        XCTAssertEqual(recommendation.defaultAction, .revealOnly)
    }

    func testFlagsHumanReadableApplicationSupportFolderForUninstalledApp() throws {
        let appSupport = temporaryRoot
            .appendingPathComponent("Library/Application Support/Old Drawing App", isDirectory: true)
        try writeFile(at: appSupport.appendingPathComponent("Library.db"), byteCount: 4_096)

        var config = tinyConfig()
        config.enableAppLeftoverScan = true
        config.installedAppSearchRoots = [temporaryRoot.appendingPathComponent("Applications", isDirectory: true)]

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: config
        ).scan()

        let recommendation = try XCTUnwrap(
            result.recommendations.first {
                samePath($0.path, appSupport.path) && $0.category == .leftovers
            }
        )

        XCTAssertEqual(recommendation.confidence, .low)
        XCTAssertEqual(recommendation.defaultAction, .revealOnly)
    }

    func testFlagsHiddenConfigurationFolderForUninstalledApp() throws {
        let hammerspoonConfig = temporaryRoot
            .appendingPathComponent(".hammerspoon", isDirectory: true)
        try writeFile(at: hammerspoonConfig.appendingPathComponent("init.lua"), byteCount: 4_096)

        var config = tinyConfig()
        config.enableAppLeftoverScan = true
        config.installedAppSearchRoots = [temporaryRoot.appendingPathComponent("Applications", isDirectory: true)]

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: config
        ).scan()

        let recommendation = try XCTUnwrap(
            result.recommendations.first {
                samePath($0.path, hammerspoonConfig.path) && $0.category == .leftovers
            }
        )

        XCTAssertEqual(recommendation.risk, .medium)
        XCTAssertEqual(recommendation.confidence, .medium)
        XCTAssertEqual(recommendation.defaultAction, .revealOnly)
    }

    func testDoesNotFlagHiddenConfigurationFolderForInstalledAppName() throws {
        let app = temporaryRoot.appendingPathComponent("Applications/Hammerspoon.app", isDirectory: true)
        try createAppBundle(
            at: app,
            bundleIdentifier: "org.hammerspoon.Hammerspoon",
            name: "Hammerspoon"
        )

        let hammerspoonConfig = temporaryRoot
            .appendingPathComponent(".hammerspoon", isDirectory: true)
        try writeFile(at: hammerspoonConfig.appendingPathComponent("init.lua"), byteCount: 4_096)

        var config = tinyConfig()
        config.enableAppLeftoverScan = true
        config.installedAppSearchRoots = [temporaryRoot.appendingPathComponent("Applications", isDirectory: true)]

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: config
        ).scan()

        XCTAssertFalse(
            result.recommendations.contains {
                samePath($0.path, hammerspoonConfig.path) && $0.category == .leftovers
            }
        )
    }

    func testFlagsConfigFolderForUninstalledApp() throws {
        let configFolder = temporaryRoot
            .appendingPathComponent(".config/Rectangle", isDirectory: true)
        try writeFile(at: configFolder.appendingPathComponent("settings.json"), byteCount: 4_096)

        var config = tinyConfig()
        config.enableAppLeftoverScan = true
        config.installedAppSearchRoots = [temporaryRoot.appendingPathComponent("Applications", isDirectory: true)]

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: config
        ).scan()

        let recommendation = try XCTUnwrap(
            result.recommendations.first {
                samePath($0.path, configFolder.path) && $0.category == .leftovers
            }
        )

        XCTAssertEqual(recommendation.confidence, .low)
        XCTAssertEqual(recommendation.defaultAction, .revealOnly)
    }

    func testFlagsDeadLaunchAgent() throws {
        let launchAgent = temporaryRoot
            .appendingPathComponent("Library/LaunchAgents/com.example.Gone.helper.plist")
        try FileManager.default.createDirectory(
            at: launchAgent.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "Label": "com.example.Gone.helper",
            "Program": temporaryRoot.appendingPathComponent("MissingHelper").path
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: launchAgent)

        var config = tinyConfig()
        config.enableAppLeftoverScan = true
        config.installedAppSearchRoots = [temporaryRoot.appendingPathComponent("Applications", isDirectory: true)]

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: config
        ).scan()

        let recommendation = try XCTUnwrap(
            result.recommendations.first {
                samePath($0.path, launchAgent.path) && $0.category == .leftovers
            }
        )

        XCTAssertEqual(recommendation.defaultAction, .revealOnly)
    }

    func testFlagsGenericBuildArtifactsInDeveloperRoots() throws {
        let projects = temporaryRoot.appendingPathComponent("Projects", isDirectory: true)
        let buildFolder = projects.appendingPathComponent("GenericTool/build", isDirectory: true)
        try writeFile(at: buildFolder.appendingPathComponent("artifact.bin"), byteCount: 4_096)

        var config = tinyConfig()
        config.developerSearchRoots = [projects]

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: config
        ).scan()

        let recommendation = try XCTUnwrap(
            result.recommendations.first {
                samePath($0.path, buildFolder.path) && $0.category == .buildArtifacts
            }
        )

        XCTAssertEqual(recommendation.risk, .medium)
        XCTAssertEqual(recommendation.defaultAction, .moveToTrash)
    }

    private func tinyConfig() -> ScannerConfig {
        ScannerConfig(
            minimumDownloadBytes: 1,
            largeDownloadBytes: 1_000_000,
            minimumCacheBytes: 1,
            minimumLogBytes: 1,
            minimumDeveloperArtifactBytes: 1,
            oldDownloadDays: 0,
            oldCacheDays: 0,
            oldLogDays: 0,
            staleProjectDays: 0,
            projectSearchDepth: 4,
            minimumLeftoverBytes: 1,
            leftoverStaleDays: 0,
            enableAppLeftoverScan: false,
            includeRunningApplicationsInAppInventory: false,
            includeRunningProcessScan: false,
            includeSystemAppTraceScan: false
        )
    }

    private func createUnityProject(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("ProjectSettings", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "m_EditorVersion: 6000.3.10f1\n".write(
            to: url.appendingPathComponent("ProjectSettings/ProjectVersion.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func createAppBundle(
        at url: URL,
        bundleIdentifier: String,
        name: String
    ) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contents,
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": name,
            "CFBundleExecutable": name
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func writeFile(at url: URL, byteCount: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data(repeating: 0x1, count: byteCount)
        try data.write(to: url)
    }

    private func samePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).resolvingSymlinksInPath().path ==
            URL(fileURLWithPath: rhs).resolvingSymlinksInPath().path
    }
}
