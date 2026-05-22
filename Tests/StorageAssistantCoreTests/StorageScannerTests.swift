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

    func testSystemDataBreakdownMeasuresVisibleLibraryContributors() throws {
        let appSupport = temporaryRoot
            .appendingPathComponent("Library/Application Support/LargeLocalIndex", isDirectory: true)
        let cache = temporaryRoot
            .appendingPathComponent("Library/Caches/com.example.Cache", isDirectory: true)
        try writeFile(at: appSupport.appendingPathComponent("index.bin"), byteCount: 4_096)
        try writeFile(at: cache.appendingPathComponent("cache.bin"), byteCount: 2_048)

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: tinyConfig()
        ).scan()

        let breakdown = try XCTUnwrap(result.systemDataBreakdown)
        XCTAssertGreaterThan(breakdown.totalKnownBytes, 0)

        let appSupportEntry = try XCTUnwrap(
            breakdown.entries.first { samePath($0.path ?? "", appSupport.deletingLastPathComponent().path) }
        )
        XCTAssertEqual(appSupportEntry.category, .userLibrary)
        XCTAssertTrue(
            appSupportEntry.contributors.contains {
                samePath($0.path, appSupport.path)
            }
        )

        let cacheRecommendation = try XCTUnwrap(
            result.recommendations.first {
                samePath($0.path, cache.path)
            }
        )
        XCTAssertTrue(cacheRecommendation.canMoveToTrash)
        XCTAssertEqual(cacheRecommendation.category, .caches)
        XCTAssertTrue(breakdown.staleItems.isEmpty)
    }

    func testSystemDataReviewItemsBecomeLeftoverRecommendations() throws {
        let appSupport = temporaryRoot
            .appendingPathComponent("Library/Application Support/com.example.StaleSupport", isDirectory: true)
        try writeFile(
            at: appSupport.appendingPathComponent("state.bin"),
            byteCount: 11 * 1_024 * 1_024
        )

        var config = tinyConfig()
        config.enableAppLeftoverScan = true
        config.installedAppSearchRoots = [temporaryRoot.appendingPathComponent("Applications", isDirectory: true)]

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: config
        ).scan()

        let recommendation = try XCTUnwrap(
            result.recommendations.first {
                samePath($0.path, appSupport.path)
            }
        )
        XCTAssertEqual(recommendation.category, .leftovers)
        XCTAssertEqual(recommendation.defaultAction, .revealOnly)
        XCTAssertTrue(result.systemDataBreakdown?.staleItems.isEmpty ?? false)
    }

    func testDirectoryAgeUsesDescendantActivityForCachesAndSystemData() throws {
        let now = Date()
        let oldDate = now.addingTimeInterval(-400 * 24 * 60 * 60)
        let recentDate = now.addingTimeInterval(-60)
        let cache = temporaryRoot
            .appendingPathComponent("Library/Caches/com.example.ActiveCache", isDirectory: true)
        let nested = cache.appendingPathComponent("Nested", isDirectory: true)
        let activeFile = nested.appendingPathComponent("today.bin")

        try writeFile(at: activeFile, byteCount: 4_096)
        try setModificationDate(recentDate, for: activeFile)
        try setModificationDate(oldDate, for: nested)
        try setModificationDate(oldDate, for: cache)

        var config = tinyConfig()
        config.oldCacheDays = 30

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: config,
            now: now
        ).scan()

        XCTAssertFalse(
            result.recommendations.contains {
                samePath($0.path, cache.path) && $0.category == .caches
            }
        )
        XCTAssertFalse(
            result.systemDataBreakdown?.staleItems.contains {
                samePath($0.path, cache.path)
            } ?? false
        )
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

    func testFlagsNestedStaleApplicationSupportFolderUnderActiveVendorFolder() throws {
        let now = Date()
        let oldDate = now.addingTimeInterval(-400 * 24 * 60 * 60)
        let recentDate = now.addingTimeInterval(-60)
        let vendor = temporaryRoot
            .appendingPathComponent("Library/Application Support/Acme", isDirectory: true)
        let retiredAppSupport = vendor.appendingPathComponent("Retired Sketch", isDirectory: true)
        let activeAppSupport = vendor.appendingPathComponent("Current Painter", isDirectory: true)
        let retiredFile = retiredAppSupport.appendingPathComponent("state.db")
        let activeFile = activeAppSupport.appendingPathComponent("state.db")

        try writeFile(at: retiredFile, byteCount: 4_096)
        try writeFile(at: activeFile, byteCount: 4_096)
        try setActivityDate(oldDate, for: retiredFile)
        try setActivityDate(oldDate, for: retiredAppSupport)
        try setActivityDate(recentDate, for: activeFile)
        try setActivityDate(recentDate, for: activeAppSupport)
        try setActivityDate(oldDate, for: vendor)

        var config = tinyConfig()
        config.enableAppLeftoverScan = true
        config.leftoverStaleDays = 90
        config.installedAppSearchRoots = [temporaryRoot.appendingPathComponent("Applications", isDirectory: true)]

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: config,
            now: now
        ).scan()

        let recommendation = try XCTUnwrap(
            result.recommendations.first {
                samePath($0.path, retiredAppSupport.path) && $0.category == .leftovers
            }
        )

        XCTAssertEqual(recommendation.confidence, .low)
        XCTAssertEqual(recommendation.defaultAction, .revealOnly)
        XCTAssertFalse(
            result.recommendations.contains {
                samePath($0.path, activeAppSupport.path) && $0.category == .leftovers
            }
        )
        XCTAssertFalse(
            result.recommendations.contains {
                samePath($0.path, vendor.path) && $0.category == .leftovers
            }
        )
    }

    func testDoesNotFlagNestedApplicationSupportFolderForInstalledAppName() throws {
        let app = temporaryRoot.appendingPathComponent("Applications/Retired Sketch.app", isDirectory: true)
        try createAppBundle(
            at: app,
            bundleIdentifier: "com.example.RetiredSketch",
            name: "Retired Sketch"
        )

        let nestedAppSupport = temporaryRoot
            .appendingPathComponent("Library/Application Support/Acme/Retired Sketch", isDirectory: true)
        try writeFile(at: nestedAppSupport.appendingPathComponent("state.db"), byteCount: 4_096)

        var config = tinyConfig()
        config.enableAppLeftoverScan = true
        config.installedAppSearchRoots = [temporaryRoot.appendingPathComponent("Applications", isDirectory: true)]

        let result = StorageScanner(
            homeDirectory: temporaryRoot,
            config: config
        ).scan()

        XCTAssertFalse(
            result.recommendations.contains {
                samePath($0.path, nestedAppSupport.path) && $0.category == .leftovers
            }
        )
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

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    private func setActivityDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes(
            [
                .creationDate: date,
                .modificationDate: date
            ],
            ofItemAtPath: url.path
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmm.ss"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        process.arguments = ["-amt", formatter.string(from: date), url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func samePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).resolvingSymlinksInPath().path ==
            URL(fileURLWithPath: rhs).resolvingSymlinksInPath().path
    }
}
