import Foundation

public struct ScannerConfig: Hashable, Sendable {
    public var minimumDownloadBytes: Int64
    public var largeDownloadBytes: Int64
    public var minimumCacheBytes: Int64
    public var minimumLogBytes: Int64
    public var minimumDeveloperArtifactBytes: Int64
    public var oldDownloadDays: Int
    public var oldCacheDays: Int
    public var oldLogDays: Int
    public var staleProjectDays: Int
    public var projectSearchDepth: Int
    public var minimumLeftoverBytes: Int64
    public var leftoverStaleDays: Int
    public var enableAppLeftoverScan: Bool
    public var installedAppSearchRoots: [URL]?
    public var includeRunningApplicationsInAppInventory: Bool
    public var includeRunningProcessScan: Bool
    public var includeSystemAppTraceScan: Bool
    public var enableSystemDataBreakdown: Bool
    public var developerSearchRoots: [URL]?

    public static let `default` = ScannerConfig(
        minimumDownloadBytes: 100 * 1_024 * 1_024,
        largeDownloadBytes: 1_024 * 1_024 * 1_024,
        minimumCacheBytes: 100 * 1_024 * 1_024,
        minimumLogBytes: 50 * 1_024 * 1_024,
        minimumDeveloperArtifactBytes: 250 * 1_024 * 1_024,
        oldDownloadDays: 30,
        oldCacheDays: 30,
        oldLogDays: 14,
        staleProjectDays: 90,
        projectSearchDepth: 5,
        minimumLeftoverBytes: 10 * 1_024 * 1_024,
        leftoverStaleDays: 90,
        enableAppLeftoverScan: true,
        installedAppSearchRoots: nil,
        includeRunningApplicationsInAppInventory: true,
        includeRunningProcessScan: true,
        includeSystemAppTraceScan: true,
        enableSystemDataBreakdown: true,
        developerSearchRoots: nil
    )

    public init(
        minimumDownloadBytes: Int64,
        largeDownloadBytes: Int64,
        minimumCacheBytes: Int64,
        minimumLogBytes: Int64,
        minimumDeveloperArtifactBytes: Int64,
        oldDownloadDays: Int,
        oldCacheDays: Int,
        oldLogDays: Int,
        staleProjectDays: Int,
        projectSearchDepth: Int,
        minimumLeftoverBytes: Int64 = 10 * 1_024 * 1_024,
        leftoverStaleDays: Int = 90,
        enableAppLeftoverScan: Bool = true,
        installedAppSearchRoots: [URL]? = nil,
        includeRunningApplicationsInAppInventory: Bool = true,
        includeRunningProcessScan: Bool = true,
        includeSystemAppTraceScan: Bool = true,
        enableSystemDataBreakdown: Bool = true,
        developerSearchRoots: [URL]? = nil
    ) {
        self.minimumDownloadBytes = minimumDownloadBytes
        self.largeDownloadBytes = largeDownloadBytes
        self.minimumCacheBytes = minimumCacheBytes
        self.minimumLogBytes = minimumLogBytes
        self.minimumDeveloperArtifactBytes = minimumDeveloperArtifactBytes
        self.oldDownloadDays = oldDownloadDays
        self.oldCacheDays = oldCacheDays
        self.oldLogDays = oldLogDays
        self.staleProjectDays = staleProjectDays
        self.projectSearchDepth = projectSearchDepth
        self.minimumLeftoverBytes = minimumLeftoverBytes
        self.leftoverStaleDays = leftoverStaleDays
        self.enableAppLeftoverScan = enableAppLeftoverScan
        self.installedAppSearchRoots = installedAppSearchRoots
        self.includeRunningApplicationsInAppInventory = includeRunningApplicationsInAppInventory
        self.includeRunningProcessScan = includeRunningProcessScan
        self.includeSystemAppTraceScan = includeSystemAppTraceScan
        self.enableSystemDataBreakdown = enableSystemDataBreakdown
        self.developerSearchRoots = developerSearchRoots
    }
}

public final class StorageScanner {
    private struct DeveloperArtifacts {
        var unityProjects: Set<URL> = []
        var nodeModules: Set<URL> = []
        var pythonEnvironments: Set<URL> = []
        var buildArtifacts: Set<URL> = []
    }

    private struct SystemDataCandidate {
        let url: URL
        let title: String
        let category: SystemDataCategory
        let detail: String
    }

    private struct SystemDataMeasurement {
        let sizeBytes: Int64
        let contributors: [SystemDataContributor]
        let staleItems: [SystemDataStaleItem]
    }

    private struct LocalSnapshotSummary {
        let count: Int
        let totalBytes: Int64?
        let names: [String]
    }

    private struct DirectoryMeasurement {
        let allocatedSize: Int64
        let latestActivityDate: Date?
    }

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let config: ScannerConfig
    private let now: Date
    private let progressHandler: (@Sendable (ScanProgress) -> Void)?
    private let shouldCancel: @Sendable () -> Bool
    private var diagnostics: [PermissionDiagnostic] = []
    private var directoryMeasurementCache: [String: DirectoryMeasurement] = [:]

    public init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        config: ScannerConfig = .default,
        now: Date = Date(),
        progressHandler: (@Sendable (ScanProgress) -> Void)? = nil,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.config = config
        self.now = now
        self.progressHandler = progressHandler
        self.shouldCancel = shouldCancel
    }

    public func scan() -> ScanResult {
        directoryMeasurementCache.removeAll()
        var recommendations: [Recommendation] = []
        report("Scanning Downloads", url: homeDirectory.appendingPathComponent("Downloads", isDirectory: true))
        recommendations += scanDownloads()
        guard !isCancelled else { return makeResult(recommendations) }

        report("Measuring Trash", url: homeDirectory.appendingPathComponent(".Trash", isDirectory: true))
        recommendations += scanTrash()
        guard !isCancelled else { return makeResult(recommendations) }

        report("Scanning user caches", url: homeDirectory.appendingPathComponent("Library/Caches", isDirectory: true))
        recommendations += scanUserCaches()
        guard !isCancelled else { return makeResult(recommendations) }

        report("Scanning user logs", url: homeDirectory.appendingPathComponent("Library/Logs", isDirectory: true))
        recommendations += scanUserLogs()
        guard !isCancelled else { return makeResult(recommendations) }

        report("Scanning developer storage")
        recommendations += scanDeveloperTools()
        guard !isCancelled else { return makeResult(recommendations) }

        if config.enableAppLeftoverScan {
            report("Scanning app leftovers and background services")
            recommendations += scanAppLeftovers()
        }
        guard !isCancelled else { return makeResult(recommendations) }

        let systemDataBreakdown: SystemDataBreakdown?
        if config.enableSystemDataBreakdown {
            report("Measuring visible System Data contributors")
            let breakdown = scanSystemDataBreakdown()
            recommendations += systemDataReviewRecommendations(from: breakdown.staleItems)
            systemDataBreakdown = SystemDataBreakdown(
                entries: breakdown.entries,
                notes: breakdown.notes
            )
        } else {
            systemDataBreakdown = nil
        }

        let sorted = deduplicateByPath(recommendations).sorted {
            if $0.risk != $1.risk {
                return riskSortValue($0.risk) < riskSortValue($1.risk)
            }
            return $0.sizeBytes > $1.sizeBytes
        }

        return makeResult(sorted, systemDataBreakdown: systemDataBreakdown)
    }

    private func scanDownloads() -> [Recommendation] {
        let downloads = homeDirectory.appendingPathComponent("Downloads", isDirectory: true)
        guard fileManager.storageAssistantFileExists(at: downloads) else {
            return []
        }

        return immediateChildren(of: downloads).compactMap { url in
            guard let metadata = fileManager.storageAssistantMetadata(for: url), !metadata.isSymbolicLink else {
                return nil
            }

            let size = itemSize(url, metadata: metadata)
            guard size >= config.minimumDownloadBytes else {
                return nil
            }

            let ageDate = latestActivityDate(for: url, metadata: metadata)
            let ageDays = StorageFormatting.daysSince(ageDate, now: now) ?? 0
            let isDisposableType = isLikelyDisposableDownload(url)
            let isVeryLarge = size >= config.largeDownloadBytes
            let isOldEnough = ageDays >= config.oldDownloadDays

            guard isDisposableType || isVeryLarge || isOldEnough else {
                return nil
            }

            let risk: RiskLevel = isDisposableType ? .medium : .high
            let action: CleanupAction = risk == .high ? .revealOnly : .moveToTrash
            let reason = downloadReason(
                url: url,
                size: size,
                ageDate: ageDate,
                isDisposableType: isDisposableType,
                isVeryLarge: isVeryLarge
            )

            return recommendation(
                url: url,
                metadata: metadata,
                displayName: url.lastPathComponent,
                category: .downloads,
                risk: risk,
                confidence: isDisposableType ? .medium : .low,
                sizeBytes: size,
                reason: reason,
                detail: "Downloads are often temporary, but this item may still matter. Review it before removing.",
                defaultAction: action
            )
        }
    }

    private func scanTrash() -> [Recommendation] {
        let trash = homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
        guard
            fileManager.storageAssistantFileExists(at: trash),
            let metadata = fileManager.storageAssistantMetadata(for: trash)
        else {
            return []
        }

        let size = itemSize(trash, metadata: metadata)
        guard size > 0 else {
            return []
        }

        return [
            recommendation(
                url: trash,
                metadata: metadata,
                displayName: "Trash contents",
                category: .trash,
                risk: .low,
                confidence: .high,
                sizeBytes: size,
                reason: "\(StorageFormatting.bytes(size)) is already in the Trash.",
                detail: "Storage Assistant does not empty Trash directly in 0.1. Reveal it in Finder and empty it there when ready.",
                defaultAction: .revealOnly
            )
        ]
    }

    private func scanUserCaches() -> [Recommendation] {
        let caches = homeDirectory.appendingPathComponent("Library/Caches", isDirectory: true)
        guard fileManager.storageAssistantFileExists(at: caches) else {
            return []
        }

        return immediateChildren(of: caches).compactMap { url in
            guard let metadata = fileManager.storageAssistantMetadata(for: url), !metadata.isSymbolicLink else {
                return nil
            }

            let size = itemSize(url, metadata: metadata)
            guard size >= config.minimumCacheBytes else {
                return nil
            }

            let ageDate = latestActivityDate(for: url, metadata: metadata)
            let ageDays = StorageFormatting.daysSince(ageDate, now: now)
            guard (ageDays ?? config.oldCacheDays) >= config.oldCacheDays else {
                return nil
            }

            return recommendation(
                url: url,
                metadata: metadata,
                displayName: "\(url.lastPathComponent) cache",
                category: .caches,
                risk: .low,
                confidence: .high,
                sizeBytes: size,
                reason: "Cache folder, \(StorageFormatting.bytes(size)), last used or changed \(StorageFormatting.agePhrase(for: ageDate, now: now)).",
                detail: "Caches are normally recreated by apps. Close the related app before moving its cache to Trash.",
                defaultAction: .moveToTrash
            )
        }
    }

    private func scanUserLogs() -> [Recommendation] {
        let logs = homeDirectory.appendingPathComponent("Library/Logs", isDirectory: true)
        guard fileManager.storageAssistantFileExists(at: logs) else {
            return []
        }

        return immediateChildren(of: logs).compactMap { url in
            guard let metadata = fileManager.storageAssistantMetadata(for: url), !metadata.isSymbolicLink else {
                return nil
            }

            let size = itemSize(url, metadata: metadata)
            guard size >= config.minimumLogBytes else {
                return nil
            }

            let ageDate = latestActivityDate(for: url, metadata: metadata)
            let ageDays = StorageFormatting.daysSince(ageDate, now: now)
            guard (ageDays ?? config.oldLogDays) >= config.oldLogDays else {
                return nil
            }

            return recommendation(
                url: url,
                metadata: metadata,
                displayName: "\(url.lastPathComponent) logs",
                category: .logs,
                risk: .low,
                confidence: .high,
                sizeBytes: size,
                reason: "Log data, \(StorageFormatting.bytes(size)), last used or changed \(StorageFormatting.agePhrase(for: ageDate, now: now)).",
                detail: "Logs are useful for debugging but are usually removable once no longer needed.",
                defaultAction: .moveToTrash
            )
        }
    }

    private func scanDeveloperTools() -> [Recommendation] {
        var recommendations: [Recommendation] = []
        guard !isCancelled else { return recommendations }

        report("Discovering developer projects")
        let artifacts = discoverDeveloperArtifacts()

        report("Scanning Unity storage")
        recommendations += scanUnity(artifacts: artifacts)
        guard !isCancelled else { return recommendations }

        report("Scanning Xcode storage")
        recommendations += scanXcode()
        guard !isCancelled else { return recommendations }

        report("Scanning Docker storage")
        recommendations += scanDocker()
        guard !isCancelled else { return recommendations }

        report("Scanning Python storage")
        recommendations += scanPython(artifacts: artifacts)
        guard !isCancelled else { return recommendations }

        report("Scanning Node storage")
        recommendations += scanNode(artifacts: artifacts)
        guard !isCancelled else { return recommendations }

        report("Scanning Homebrew storage")
        recommendations += scanHomebrew()
        guard !isCancelled else { return recommendations }

        report("Scanning generic build artifacts")
        recommendations += scanBuildArtifacts(artifacts: artifacts)

        return recommendations
    }

    private func scanUnity(artifacts: DeveloperArtifacts) -> [Recommendation] {
        var recommendations: [Recommendation] = []

        let unityCacheCandidates = [
            homeDirectory.appendingPathComponent("Library/Unity/cache", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Unity/Asset Store-5.x", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Caches/com.unity3d.UnityEditor", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Caches/com.unity3d.UnityHub", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Application Support/Unity/Asset Store-5.x", isDirectory: true)
        ]

        for url in unityCacheCandidates {
            guard !isCancelled else { return recommendations }

            guard
                fileManager.storageAssistantFileExists(at: url),
                let metadata = fileManager.storageAssistantMetadata(for: url)
            else {
                continue
            }

            let size = itemSize(url, metadata: metadata)
            guard size >= config.minimumDeveloperArtifactBytes else {
                continue
            }

            let isAssetStoreCache = url.path.contains("Asset Store")
            recommendations.append(
                recommendation(
                    url: url,
                    metadata: metadata,
                    displayName: isAssetStoreCache ? "Unity Asset Store cache" : "Unity cache",
                    category: .unity,
                    risk: isAssetStoreCache ? .medium : .low,
                    confidence: .medium,
                    sizeBytes: size,
                    reason: "Unity cache data using \(StorageFormatting.bytes(size)).",
                    detail: isAssetStoreCache
                        ? "Asset Store downloads may be redownloadable, but review before removing older packages."
                        : "Unity can normally recreate editor and package caches.",
                    defaultAction: .moveToTrash
                )
            )
        }

        let editorRoot = URL(fileURLWithPath: "/Applications/Unity/Hub/Editor", isDirectory: true)
        if
            fileManager.storageAssistantFileExists(at: editorRoot),
            let metadata = fileManager.storageAssistantMetadata(for: editorRoot)
        {
            let size = itemSize(editorRoot, metadata: metadata)
            if size >= 1_024 * 1_024 * 1_024 {
                recommendations.append(
                    recommendation(
                        url: editorRoot,
                        metadata: metadata,
                        displayName: "Installed Unity editor versions",
                        category: .unity,
                        risk: .high,
                        confidence: .medium,
                        sizeBytes: size,
                        reason: "Unity Hub editor installs are using \(StorageFormatting.bytes(size)).",
                        detail: "Projects can depend on exact Unity versions. Remove old editors through Unity Hub after checking project requirements.",
                        defaultAction: .revealOnly
                    )
                )
            }
        }

        for project in artifacts.unityProjects.sorted(by: { $0.path < $1.path }) {
            guard !isCancelled else { return recommendations }
            report("Measuring Unity project", url: project)
            recommendations += scanUnityProject(project)
        }

        return recommendations
    }

    private func scanUnityProject(_ project: URL) -> [Recommendation] {
        var recommendations: [Recommendation] = []
        let projectName = project.lastPathComponent
        let projectVersion = unityProjectVersion(for: project)

        let generatedFolders: [(name: String, minimumSize: Int64, risk: RiskLevel, confidence: ConfidenceLevel, detail: String)] = [
            (
                "Library",
                500 * 1_024 * 1_024,
                .medium,
                .high,
                "Unity can regenerate a project's Library folder, but the next project open can take a while."
            ),
            (
                "Temp",
                50 * 1_024 * 1_024,
                .low,
                .high,
                "Unity temporary project data is normally disposable when the editor is closed."
            ),
            (
                "Obj",
                50 * 1_024 * 1_024,
                .low,
                .medium,
                "Generated object/build intermediates are usually safe to remove when the project is closed."
            ),
            (
                "Logs",
                50 * 1_024 * 1_024,
                .low,
                .medium,
                "Unity project logs are useful for debugging but usually removable later."
            ),
            (
                "Build",
                500 * 1_024 * 1_024,
                .medium,
                .low,
                "Build outputs may be deliverables. Review the contents before removing."
            ),
            (
                "Builds",
                500 * 1_024 * 1_024,
                .medium,
                .low,
                "Build outputs may be deliverables. Review the contents before removing."
            )
        ]

        for folder in generatedFolders {
            guard !isCancelled else { return recommendations }

            let url = project.appendingPathComponent(folder.name, isDirectory: true)
            guard
                fileManager.storageAssistantFileExists(at: url),
                let metadata = fileManager.storageAssistantMetadata(for: url)
            else {
                continue
            }

            let size = itemSize(url, metadata: metadata)
            let minimumSize = min(folder.minimumSize, config.minimumDeveloperArtifactBytes)
            guard size >= minimumSize else {
                continue
            }

            let versionText = projectVersion.map { " Unity \($0)." } ?? ""
            recommendations.append(
                recommendation(
                    url: url,
                    metadata: metadata,
                    displayName: "\(projectName) \(folder.name)",
                    category: .unity,
                    risk: folder.risk,
                    confidence: folder.confidence,
                    sizeBytes: size,
                    reason: "Unity project \(folder.name) folder, \(StorageFormatting.bytes(size)).\(versionText)",
                    detail: folder.detail,
                    defaultAction: folder.risk == .high ? .revealOnly : .moveToTrash
                )
            )
        }

        return recommendations
    }

    private func scanXcode() -> [Recommendation] {
        let candidates: [(url: URL, name: String, risk: RiskLevel, confidence: ConfidenceLevel, action: CleanupAction, detail: String, command: CommandSuggestion?)] = [
            (
                homeDirectory.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true),
                "Xcode DerivedData",
                .low,
                .high,
                .moveToTrash,
                "Xcode can regenerate DerivedData, though rebuilds may take longer afterward.",
                nil
            ),
            (
                homeDirectory.appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true),
                "Xcode Archives",
                .medium,
                .medium,
                .moveToTrash,
                "Archives can contain builds you shipped or may need later. Review before removing.",
                nil
            ),
            (
                homeDirectory.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true),
                "Xcode iOS DeviceSupport",
                .medium,
                .medium,
                .moveToTrash,
                "Old device support files can often be recreated, but check whether you still debug those iOS versions.",
                nil
            ),
            (
                homeDirectory.appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true),
                "CoreSimulator devices",
                .medium,
                .medium,
                .commandRecommended,
                "Simulator devices are best removed through Xcode or xcrun simctl, not by deleting blindly.",
                CommandSuggestion(
                    command: "xcrun simctl delete unavailable",
                    reason: "Xcode's simulator tooling can remove unavailable simulator devices safely."
                )
            )
        ]

        return candidates.compactMap { candidate in
            guard
                fileManager.storageAssistantFileExists(at: candidate.url),
                let metadata = fileManager.storageAssistantMetadata(for: candidate.url)
            else {
                return nil
            }

            let size = itemSize(candidate.url, metadata: metadata)
            guard size >= config.minimumDeveloperArtifactBytes else {
                return nil
            }

            return recommendation(
                url: candidate.url,
                metadata: metadata,
                displayName: candidate.name,
                category: .xcode,
                risk: candidate.risk,
                confidence: candidate.confidence,
                sizeBytes: size,
                reason: "\(candidate.name) is using \(StorageFormatting.bytes(size)).",
                detail: candidate.detail,
                defaultAction: candidate.action,
                commandSuggestion: candidate.command
            )
        }
    }

    private func scanDocker() -> [Recommendation] {
        var recommendations: [Recommendation] = []
        let diskImageCandidates = [
            homeDirectory.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"),
            homeDirectory.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.qcow2")
        ]

        for url in diskImageCandidates {
            guard !isCancelled else { return recommendations }

            guard
                fileManager.storageAssistantFileExists(at: url),
                let metadata = fileManager.storageAssistantMetadata(for: url)
            else {
                continue
            }

            let size = itemSize(url, metadata: metadata)
            guard size >= config.largeDownloadBytes else {
                continue
            }

            recommendations.append(
                recommendation(
                    url: url,
                    metadata: metadata,
                    displayName: "Docker Desktop disk image",
                    category: .docker,
                    risk: .high,
                    confidence: .high,
                    sizeBytes: size,
                    reason: "Docker Desktop storage image is using \(StorageFormatting.bytes(size)).",
                    detail: "Do not delete this file directly while Docker Desktop is installed. Use Docker Desktop cleanup or docker prune commands.",
                    defaultAction: .commandRecommended,
                    commandSuggestion: CommandSuggestion(
                        command: "docker system df && docker system prune",
                        reason: "Docker should clean images, containers, and build cache through its own tooling."
                    )
                )
            )
        }

        let dockerCache = homeDirectory.appendingPathComponent("Library/Caches/com.docker.docker", isDirectory: true)
        if
            fileManager.storageAssistantFileExists(at: dockerCache),
            let metadata = fileManager.storageAssistantMetadata(for: dockerCache)
        {
            let size = itemSize(dockerCache, metadata: metadata)
            if size >= config.minimumDeveloperArtifactBytes {
                recommendations.append(
                    recommendation(
                        url: dockerCache,
                        metadata: metadata,
                        displayName: "Docker Desktop cache",
                        category: .docker,
                        risk: .medium,
                        confidence: .medium,
                        sizeBytes: size,
                        reason: "Docker Desktop cache is using \(StorageFormatting.bytes(size)).",
                        detail: "Cache files are usually removable, but quit Docker Desktop before moving them to Trash.",
                        defaultAction: .moveToTrash
                    )
                )
            }
        }

        return recommendations
    }

    private func scanPython(artifacts: DeveloperArtifacts) -> [Recommendation] {
        var recommendations: [Recommendation] = []

        let cacheCandidates = [
            homeDirectory.appendingPathComponent("Library/Caches/pip", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Caches/pypoetry", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Caches/uv", isDirectory: true)
        ]

        for url in cacheCandidates {
            guard !isCancelled else { return recommendations }

            guard
                fileManager.storageAssistantFileExists(at: url),
                let metadata = fileManager.storageAssistantMetadata(for: url)
            else {
                continue
            }

            let size = itemSize(url, metadata: metadata)
            guard size >= config.minimumDeveloperArtifactBytes else {
                continue
            }

            recommendations.append(
                recommendation(
                    url: url,
                    metadata: metadata,
                    displayName: "\(url.lastPathComponent) cache",
                    category: .python,
                    risk: .low,
                    confidence: .high,
                    sizeBytes: size,
                    reason: "Python package cache using \(StorageFormatting.bytes(size)).",
                    detail: "Package caches can usually be regenerated by pip, Poetry, or uv.",
                    defaultAction: .moveToTrash
                )
            )
        }

        for url in artifacts.pythonEnvironments.sorted(by: { $0.path < $1.path }) {
            guard !isCancelled else { return recommendations }

            guard let metadata = fileManager.storageAssistantMetadata(for: url) else {
                continue
            }

            let size = itemSize(url, metadata: metadata)
            guard size >= config.minimumDeveloperArtifactBytes else {
                continue
            }

            recommendations.append(
                recommendation(
                    url: url,
                    metadata: metadata,
                    displayName: "\(url.deletingLastPathComponent().lastPathComponent) \(url.lastPathComponent)",
                    category: .python,
                    risk: .medium,
                    confidence: .high,
                    sizeBytes: size,
                    reason: "Python virtual environment using \(StorageFormatting.bytes(size)).",
                    detail: "Virtual environments are usually rebuildable from dependency files, but review the project first.",
                    defaultAction: .moveToTrash
                )
            )
        }

        return recommendations
    }

    private func scanNode(artifacts: DeveloperArtifacts) -> [Recommendation] {
        var recommendations: [Recommendation] = []

        let cacheCandidates = [
            homeDirectory.appendingPathComponent(".npm", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Caches/Yarn", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Caches/pnpm", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/pnpm/store", isDirectory: true)
        ]

        for url in cacheCandidates {
            guard !isCancelled else { return recommendations }

            guard
                fileManager.storageAssistantFileExists(at: url),
                let metadata = fileManager.storageAssistantMetadata(for: url)
            else {
                continue
            }

            let size = itemSize(url, metadata: metadata)
            guard size >= config.minimumDeveloperArtifactBytes else {
                continue
            }

            recommendations.append(
                recommendation(
                    url: url,
                    metadata: metadata,
                    displayName: "\(url.lastPathComponent) package cache",
                    category: .node,
                    risk: .low,
                    confidence: .high,
                    sizeBytes: size,
                    reason: "Node package cache using \(StorageFormatting.bytes(size)).",
                    detail: "Package manager caches are usually rebuildable by npm, Yarn, or pnpm.",
                    defaultAction: .moveToTrash
                )
            )
        }

        for url in artifacts.nodeModules.sorted(by: { $0.path < $1.path }) {
            guard !isCancelled else { return recommendations }

            guard let metadata = fileManager.storageAssistantMetadata(for: url) else {
                continue
            }

            let size = itemSize(url, metadata: metadata)
            guard size >= config.minimumDeveloperArtifactBytes else {
                continue
            }

            recommendations.append(
                recommendation(
                    url: url,
                    metadata: metadata,
                    displayName: "\(url.deletingLastPathComponent().lastPathComponent) node_modules",
                    category: .node,
                    risk: .medium,
                    confidence: .high,
                    sizeBytes: size,
                    reason: "node_modules folder using \(StorageFormatting.bytes(size)).",
                    detail: "node_modules is usually rebuildable from package-lock, yarn.lock, pnpm-lock.yaml, or package.json.",
                    defaultAction: .moveToTrash
                )
            )
        }

        return recommendations
    }

    private func scanHomebrew() -> [Recommendation] {
        let cache = homeDirectory.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true)
        guard
            fileManager.storageAssistantFileExists(at: cache),
            let metadata = fileManager.storageAssistantMetadata(for: cache)
        else {
            return []
        }

        let size = itemSize(cache, metadata: metadata)
        guard size >= config.minimumDeveloperArtifactBytes else {
            return []
        }

        return [
            recommendation(
                url: cache,
                metadata: metadata,
                displayName: "Homebrew cache",
                category: .homebrew,
                risk: .low,
                confidence: .high,
                sizeBytes: size,
                reason: "Homebrew download/build cache using \(StorageFormatting.bytes(size)).",
                detail: "Homebrew can redownload cached formula files when needed.",
                defaultAction: .moveToTrash
            )
        ]
    }

    private func scanBuildArtifacts(artifacts: DeveloperArtifacts) -> [Recommendation] {
        var recommendations: [Recommendation] = []

        for url in artifacts.buildArtifacts.sorted(by: { $0.path < $1.path }) {
            guard !isCancelled else { return recommendations }
            guard !containsCurrentExecutable(url) else {
                continue
            }

            guard let metadata = fileManager.storageAssistantMetadata(for: url) else {
                continue
            }

            let size = itemSize(url, metadata: metadata)
            guard size >= config.minimumDeveloperArtifactBytes else {
                continue
            }

            let projectName = url.deletingLastPathComponent().lastPathComponent
            recommendations.append(
                recommendation(
                    url: url,
                    metadata: metadata,
                    displayName: "\(projectName) \(url.lastPathComponent)",
                    category: .buildArtifacts,
                    risk: .medium,
                    confidence: .medium,
                    sizeBytes: size,
                    reason: "Generic build artifact folder using \(StorageFormatting.bytes(size)).",
                    detail: "This looks like generated project output, dependency cache, or build tooling state. Review the project before moving it to Trash.",
                    defaultAction: .moveToTrash
                )
            )
        }

        return recommendations
    }

    private struct LeftoverLocation {
        let directory: URL
        let label: String
        let risk: RiskLevel
        let confidence: ConfidenceLevel
        let action: CleanupAction
        let minimumBytes: Int64
        let requiresStaleDate: Bool
        let detail: String
    }

    private struct LaunchService {
        let url: URL
        let label: String
        let program: String?
        let arguments: [String]

        var searchableText: String {
            ([url.path, label, program] + arguments)
                .compactMap { $0 }
                .joined(separator: " ")
        }
    }

    private struct KnownLeftoverSignature {
        let displayName: String
        let keywords: [String]
        let relatedAppNames: [String]
        let relatedBundlePrefixes: [String]
        let detail: String

        func matches(_ text: String) -> Bool {
            let lowercased = text.lowercased()
            return keywords.contains { lowercased.contains($0) }
        }

        func hasInstalledRelatedApp(in inventory: InstalledAppInventory) -> Bool {
            relatedAppNames.contains { inventory.containsNameLike($0) } ||
                relatedBundlePrefixes.contains { inventory.containsBundleIdentifierLike($0) }
        }
    }

    private func scanAppLeftovers() -> [Recommendation] {
        guard !isCancelled else { return [] }

        report("Building installed app inventory")
        let inventory = InstalledAppInventory.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            applicationRoots: config.installedAppSearchRoots,
            includeRunningApplications: config.includeRunningApplicationsInAppInventory
        )

        report("Checking Library leftovers")
        var recommendations = scanLibraryLeftovers(installedApps: inventory)
        guard !isCancelled else { return recommendations }

        report("Checking app configuration leftovers")
        recommendations += scanHomeConfigurationLeftovers(installedApps: inventory)
        guard !isCancelled else { return recommendations }

        report("Checking extended app trace leftovers")
        recommendations += scanAppTraceLeftovers(installedApps: inventory)
        guard !isCancelled else { return recommendations }

        report("Checking stale app support folders")
        recommendations += scanStaleAppSupportLeftovers(installedApps: inventory)
        guard !isCancelled else { return recommendations }

        report("Checking running processes")
        let runningProcesses = config.includeRunningProcessScan
            ? RunningProcessInventory.load()
            : RunningProcessInventory(entries: [])

        report("Checking launch agents and daemons")
        recommendations += scanLaunchServiceLeftovers(
            installedApps: inventory,
            runningProcesses: runningProcesses
        )
        guard !isCancelled else { return recommendations }

        report("Checking known licensing/service leftovers")
        recommendations += scanKnownServiceLeftovers(
            installedApps: inventory,
            runningProcesses: runningProcesses
        )

        return recommendations
    }

    private struct HomeConfigurationLeftoverLocation {
        let directory: URL
        let label: String
        let scansHiddenChildren: Bool
        let minimumBytes: Int64
        let confidence: ConfidenceLevel
    }

    private enum AppTraceIdentityStyle {
        case standard
        case byHostPreference
        case groupContainer
        case cookie
        case packageReceipt
    }

    private enum AppTraceItemKind {
        case files
        case directories
        case filesAndDirectories

        func includes(_ metadata: FileMetadata) -> Bool {
            switch self {
            case .files:
                return !metadata.isDirectory
            case .directories:
                return metadata.isDirectory
            case .filesAndDirectories:
                return true
            }
        }
    }

    private enum AppTraceTraversal {
        case immediateChildren
        case childrenOfImmediateDirectories
    }

    private struct AppTraceLeftoverLocation {
        let directory: URL
        let label: String
        let risk: RiskLevel
        let confidence: ConfidenceLevel
        let minimumBytes: Int64
        let requiresStaleDate: Bool
        let itemKind: AppTraceItemKind
        let traversal: AppTraceTraversal
        let identityStyle: AppTraceIdentityStyle
        let allowedExtensions: Set<String>?
        let usesRelatedNameMatch: Bool
        let detail: String

        init(
            directory: URL,
            label: String,
            risk: RiskLevel,
            confidence: ConfidenceLevel,
            minimumBytes: Int64,
            requiresStaleDate: Bool = true,
            itemKind: AppTraceItemKind = .filesAndDirectories,
            traversal: AppTraceTraversal = .immediateChildren,
            identityStyle: AppTraceIdentityStyle = .standard,
            allowedExtensions: Set<String>? = nil,
            usesRelatedNameMatch: Bool = false,
            detail: String
        ) {
            self.directory = directory
            self.label = label
            self.risk = risk
            self.confidence = confidence
            self.minimumBytes = minimumBytes
            self.requiresStaleDate = requiresStaleDate
            self.itemKind = itemKind
            self.traversal = traversal
            self.identityStyle = identityStyle
            self.allowedExtensions = allowedExtensions
            self.usesRelatedNameMatch = usesRelatedNameMatch
            self.detail = detail
        }
    }

    private struct StaleAppSupportLocation {
        let directory: URL
        let label: String
        let risk: RiskLevel
        let confidence: ConfidenceLevel
        let minimumBytes: Int64
        let includeNestedAppFolders: Bool
        let detail: String
    }

    private func scanHomeConfigurationLeftovers(installedApps: InstalledAppInventory) -> [Recommendation] {
        let locations = [
            HomeConfigurationLeftoverLocation(
                directory: homeDirectory,
                label: "home configuration folder",
                scansHiddenChildren: true,
                minimumBytes: 1,
                confidence: .medium
            ),
            HomeConfigurationLeftoverLocation(
                directory: homeDirectory.appendingPathComponent(".config", isDirectory: true),
                label: "configuration folder",
                scansHiddenChildren: false,
                minimumBytes: config.minimumLeftoverBytes,
                confidence: .low
            )
        ]

        var recommendations: [Recommendation] = []

        for location in locations {
            guard !isCancelled else { return recommendations }
            guard fileManager.storageAssistantFileExists(at: location.directory) else {
                continue
            }

            for url in immediateChildren(of: location.directory) {
                guard !isCancelled else { return recommendations }
                guard
                    let metadata = fileManager.storageAssistantMetadata(for: url),
                    metadata.isDirectory,
                    !metadata.isSymbolicLink,
                    !isProtectedLeftoverPath(url)
                else {
                    continue
                }

                if location.scansHiddenChildren && !url.lastPathComponent.hasPrefix(".") {
                    continue
                }

                guard !isProtectedHomeConfigurationName(url.lastPathComponent) else {
                    continue
                }

                let identity = homeConfigurationIdentity(for: url)
                guard shouldFlagLeftover(identity: identity, url: url, installedApps: installedApps) else {
                    continue
                }

                let size = itemSize(url, metadata: metadata)
                guard size >= location.minimumBytes else {
                    continue
                }

                let ageDate = latestActivityDate(for: url, metadata: metadata)
                let ageDays = StorageFormatting.daysSince(ageDate, now: now)
                guard (ageDays ?? config.leftoverStaleDays) >= config.leftoverStaleDays else {
                    continue
                }

                recommendations.append(
                    recommendation(
                        url: url,
                        metadata: metadata,
                        displayName: "\(identity) \(location.label)",
                        category: .leftovers,
                        risk: .medium,
                        confidence: location.confidence,
                        sizeBytes: size,
                        reason: "\(location.label.capitalized), \(StorageFormatting.bytes(size)), but no installed app match was found.",
                        detail: "App configuration folders can contain hand-written settings or scripts. Review the contents before removing them.",
                        defaultAction: .revealOnly
                    )
                )
            }
        }

        return recommendations
    }

    private func scanStaleAppSupportLeftovers(installedApps: InstalledAppInventory) -> [Recommendation] {
        let userLibrary = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        var locations = [
            StaleAppSupportLocation(
                directory: userLibrary.appendingPathComponent("Application Support", isDirectory: true),
                label: "Application Support folder",
                risk: .medium,
                confidence: .low,
                minimumBytes: config.minimumLeftoverBytes,
                includeNestedAppFolders: true,
                detail: "Application Support can contain user data, templates, databases, or licensed assets. This folder has no obvious installed app match, but review the contents before removing it."
            )
        ]

        if config.includeSystemAppTraceScan {
            locations += [
                StaleAppSupportLocation(
                    directory: URL(fileURLWithPath: "/Library/Application Support", isDirectory: true),
                    label: "system Application Support folder",
                    risk: .high,
                    confidence: .low,
                    minimumBytes: config.minimumLeftoverBytes,
                    includeNestedAppFolders: true,
                    detail: "System-wide Application Support can affect every user on this Mac. Prefer the vendor uninstaller when one exists, and review the folder before changing it."
                ),
                StaleAppSupportLocation(
                    directory: URL(fileURLWithPath: "/Users/Shared", isDirectory: true),
                    label: "shared app support folder",
                    risk: .high,
                    confidence: .low,
                    minimumBytes: config.minimumLeftoverBytes,
                    includeNestedAppFolders: true,
                    detail: "Shared folders can contain assets, libraries, licenses, or data used by multiple user accounts. Review before removing them."
                )
            ]
        }

        var recommendations: [Recommendation] = []

        for location in locations {
            guard !isCancelled else { return recommendations }
            guard fileManager.storageAssistantFileExists(at: location.directory) else {
                continue
            }

            for url in staleAppSupportCandidates(for: location) {
                guard !isCancelled else { return recommendations }
                guard
                    let metadata = fileManager.storageAssistantMetadata(for: url),
                    metadata.isDirectory,
                    !metadata.isSymbolicLink,
                    !isProtectedLeftoverPath(url)
                else {
                    continue
                }

                let identity = leftoverIdentity(for: url)
                guard shouldFlagAppSupportLeftover(identity: identity, url: url, installedApps: installedApps) else {
                    continue
                }

                let size = itemSize(url, metadata: metadata)
                guard size >= location.minimumBytes else {
                    continue
                }

                let ageDate = latestActivityDate(for: url, metadata: metadata)
                let ageDays = StorageFormatting.daysSince(ageDate, now: now)
                guard (ageDays ?? config.leftoverStaleDays) >= config.leftoverStaleDays else {
                    continue
                }

                let knownSignature = knownLeftoverSignature(matching: "\(url.path) \(identity)")
                let displayName = knownSignature?.displayName ?? "\(identity) \(location.label)"
                let reason = knownSignature == nil
                    ? "\(StorageFormatting.bytes(size)) in \(location.label), with no installed app match found, last used or changed \(StorageFormatting.agePhrase(for: ageDate, now: now))."
                    : "\(knownSignature!.displayName) component found, \(StorageFormatting.bytes(size)), with no obvious installed owner."

                recommendations.append(
                    recommendation(
                        url: url,
                        metadata: metadata,
                        displayName: displayName,
                        category: .leftovers,
                        risk: knownSignature == nil ? location.risk : maxRisk(location.risk, .medium),
                        confidence: knownSignature == nil ? location.confidence : .high,
                        sizeBytes: size,
                        reason: reason,
                        detail: knownSignature?.detail ?? location.detail,
                        defaultAction: .revealOnly
                    )
                )
            }
        }

        return recommendations
    }

    private func scanAppTraceLeftovers(installedApps: InstalledAppInventory) -> [Recommendation] {
        let appSupportMinimum = max(config.minimumLeftoverBytes, 100 * 1_024 * 1_024)
        let preferenceMinimum = min(config.minimumLeftoverBytes, 64 * 1_024)
        let pluginMinimum = min(config.minimumLeftoverBytes, 1 * 1_024 * 1_024)
        let userLibrary = homeDirectory.appendingPathComponent("Library", isDirectory: true)

        var locations: [AppTraceLeftoverLocation] = [
            AppTraceLeftoverLocation(
                directory: userLibrary.appendingPathComponent("Containers", isDirectory: true),
                label: "app container",
                risk: .medium,
                confidence: .medium,
                minimumBytes: config.minimumLeftoverBytes,
                itemKind: .directories,
                detail: "App containers can hold documents, databases, and sandboxed app state. Review the contents before removing them."
            ),
            AppTraceLeftoverLocation(
                directory: userLibrary.appendingPathComponent("Group Containers", isDirectory: true),
                label: "group container",
                risk: .medium,
                confidence: .low,
                minimumBytes: config.minimumLeftoverBytes,
                itemKind: .directories,
                identityStyle: .groupContainer,
                detail: "Group containers can be shared by multiple apps from the same developer. Review carefully before changing them."
            ),
            AppTraceLeftoverLocation(
                directory: userLibrary.appendingPathComponent("Application Scripts", isDirectory: true),
                label: "application scripts folder",
                risk: .medium,
                confidence: .medium,
                minimumBytes: 1,
                itemKind: .directories,
                detail: "Application Scripts folders may contain user-created automation. Review the scripts before removing them."
            ),
            AppTraceLeftoverLocation(
                directory: userLibrary.appendingPathComponent("Preferences/ByHost", isDirectory: true),
                label: "ByHost preference file",
                risk: .medium,
                confidence: .medium,
                minimumBytes: preferenceMinimum,
                itemKind: .files,
                identityStyle: .byHostPreference,
                allowedExtensions: ["plist"],
                detail: "ByHost preferences are per-Mac settings. They are usually small, but review them when the owning app is gone."
            ),
            AppTraceLeftoverLocation(
                directory: userLibrary.appendingPathComponent("WebKit", isDirectory: true),
                label: "WebKit storage",
                risk: .medium,
                confidence: .medium,
                minimumBytes: config.minimumLeftoverBytes,
                detail: "WebKit storage can include local web data for an app. Review before removing it."
            ),
            AppTraceLeftoverLocation(
                directory: userLibrary.appendingPathComponent("HTTPStorages", isDirectory: true),
                label: "HTTP storage",
                risk: .medium,
                confidence: .medium,
                minimumBytes: config.minimumLeftoverBytes,
                detail: "HTTP storage can include cached responses or session data for an app. Review before removing it."
            ),
            AppTraceLeftoverLocation(
                directory: userLibrary.appendingPathComponent("Cookies", isDirectory: true),
                label: "cookie storage",
                risk: .medium,
                confidence: .low,
                minimumBytes: 1,
                itemKind: .files,
                identityStyle: .cookie,
                allowedExtensions: ["binarycookies", "cookies"],
                detail: "Cookie files can hold login/session data. Review before removing them."
            ),
            AppTraceLeftoverLocation(
                directory: userLibrary.appendingPathComponent("Application Support", isDirectory: true),
                label: "application support folder",
                risk: .medium,
                confidence: .low,
                minimumBytes: config.minimumLeftoverBytes,
                itemKind: .directories,
                usesRelatedNameMatch: true,
                detail: "Application Support can contain user data, templates, databases, or licensed assets. Review the folder before removing it."
            )
        ]

        locations += pluginTraceLocations(
            baseDirectory: userLibrary,
            risk: .medium,
            minimumBytes: pluginMinimum
        )

        if config.includeSystemAppTraceScan {
            locations += systemAppTraceLocations(
                appSupportMinimum: appSupportMinimum,
                preferenceMinimum: preferenceMinimum,
                pluginMinimum: pluginMinimum
            )
        }

        var recommendations: [Recommendation] = []

        for location in locations {
            guard !isCancelled else { return recommendations }
            guard fileManager.storageAssistantFileExists(at: location.directory) else {
                continue
            }

            for url in appTraceCandidates(for: location) {
                guard !isCancelled else { return recommendations }
                guard
                    let metadata = fileManager.storageAssistantMetadata(for: url),
                    !metadata.isSymbolicLink,
                    location.itemKind.includes(metadata),
                    !isProtectedLeftoverPath(url)
                else {
                    continue
                }

                if let allowedExtensions = location.allowedExtensions,
                   !allowedExtensions.contains(url.pathExtension.lowercased()) {
                    continue
                }

                guard
                    let identity = appTraceIdentity(for: url, style: location.identityStyle),
                    !identity.isEmpty
                else {
                    continue
                }

                if location.usesRelatedNameMatch,
                   !isBundleIdentifierCandidate(identity),
                   installedApps.containsRelatedNameLike(identity) {
                    continue
                }

                guard shouldFlagLeftover(identity: identity, url: url, installedApps: installedApps) else {
                    continue
                }

                let size = itemSize(url, metadata: metadata)
                guard size >= location.minimumBytes else {
                    continue
                }

                if location.requiresStaleDate {
                    let ageDate = latestActivityDate(for: url, metadata: metadata)
                    let ageDays = StorageFormatting.daysSince(ageDate, now: now)
                    guard (ageDays ?? config.leftoverStaleDays) >= config.leftoverStaleDays else {
                        continue
                    }
                }

                recommendations.append(
                    recommendation(
                        url: url,
                        metadata: metadata,
                        displayName: "\(identity) \(location.label)",
                        category: .leftovers,
                        risk: location.risk,
                        confidence: location.confidence,
                        sizeBytes: size,
                        reason: "\(location.label.capitalized), \(StorageFormatting.bytes(size)), but no installed app match was found.",
                        detail: location.detail,
                        defaultAction: .revealOnly
                    )
                )
            }
        }

        return recommendations
    }

    private func staleAppSupportCandidates(for location: StaleAppSupportLocation) -> [URL] {
        var seen: Set<String> = []
        var candidates: [URL] = []

        func appendCandidate(_ url: URL) {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard seen.insert(path).inserted else { return }
            candidates.append(url)
        }

        for child in immediateChildren(of: location.directory) {
            guard !isCancelled else { break }
            guard
                let metadata = fileManager.storageAssistantMetadata(for: child),
                metadata.isDirectory,
                !metadata.isSymbolicLink,
                !isProtectedLeftoverPath(child)
            else {
                continue
            }

            let nestedCandidates = location.includeNestedAppFolders
                ? nestedAppSupportCandidates(in: child)
                : []

            if nestedCandidates.isEmpty {
                appendCandidate(child)
            } else {
                nestedCandidates.forEach(appendCandidate)
            }
        }

        return candidates
    }

    private func nestedAppSupportCandidates(in parent: URL) -> [URL] {
        let parentIdentity = leftoverIdentity(for: parent)
        guard
            !isBundleIdentifierCandidate(parentIdentity),
            knownLeftoverSignature(matching: "\(parent.path) \(parentIdentity)") == nil
        else {
            return []
        }

        return immediateChildren(of: parent).compactMap { child in
            guard !isCancelled else { return nil }
            guard
                let metadata = fileManager.storageAssistantMetadata(for: child),
                metadata.isDirectory,
                !metadata.isSymbolicLink,
                !isProtectedLeftoverPath(child),
                isSpecificNestedAppSupportName(child.lastPathComponent)
            else {
                return nil
            }

            return child
        }
    }

    private func shouldFlagAppSupportLeftover(
        identity: String,
        url: URL,
        installedApps: InstalledAppInventory
    ) -> Bool {
        if isProtectedBundleIdentifier(identity) {
            return false
        }

        if knownLeftoverSignature(matching: "\(identity) \(url.path)") != nil {
            return true
        }

        if isBundleIdentifierCandidate(identity) {
            return !installedApps.containsBundleIdentifierLike(identity)
        }

        let normalized = normalizedAppToken(identity)
        guard normalized.count >= 3 else {
            return false
        }

        return !installedApps.containsRelatedNameLike(identity)
    }

    private func isSpecificNestedAppSupportName(_ name: String) -> Bool {
        let normalized = normalizedAppToken(name)
        guard normalized.count >= 3 else {
            return false
        }

        let genericNames: Set<String> = [
            "application",
            "applicationsupport",
            "assets",
            "cache",
            "caches",
            "common",
            "data",
            "database",
            "databases",
            "framework",
            "frameworks",
            "helper",
            "helpers",
            "license",
            "licenses",
            "log",
            "logs",
            "metadata",
            "plugin",
            "plugins",
            "preferences",
            "resources",
            "service",
            "services",
            "settings",
            "shared",
            "storage",
            "support",
            "temp",
            "temporary",
            "update",
            "updater",
            "updates"
        ]

        return !genericNames.contains(normalized)
    }

    private func pluginTraceLocations(
        baseDirectory: URL,
        risk: RiskLevel,
        minimumBytes: Int64
    ) -> [AppTraceLeftoverLocation] {
        let pluginDetail = "Plug-ins, preference panes, screen savers, and importers can affect other apps or the system. Review before removing them."

        return [
            AppTraceLeftoverLocation(
                directory: baseDirectory.appendingPathComponent("Audio/Plug-Ins", isDirectory: true),
                label: "audio plug-in",
                risk: risk,
                confidence: .low,
                minimumBytes: minimumBytes,
                traversal: .childrenOfImmediateDirectories,
                usesRelatedNameMatch: true,
                detail: pluginDetail
            ),
            AppTraceLeftoverLocation(
                directory: baseDirectory.appendingPathComponent("Internet Plug-Ins", isDirectory: true),
                label: "internet plug-in",
                risk: risk,
                confidence: .low,
                minimumBytes: minimumBytes,
                usesRelatedNameMatch: true,
                detail: pluginDetail
            ),
            AppTraceLeftoverLocation(
                directory: baseDirectory.appendingPathComponent("QuickLook", isDirectory: true),
                label: "Quick Look plug-in",
                risk: risk,
                confidence: .low,
                minimumBytes: minimumBytes,
                usesRelatedNameMatch: true,
                detail: pluginDetail
            ),
            AppTraceLeftoverLocation(
                directory: baseDirectory.appendingPathComponent("Spotlight", isDirectory: true),
                label: "Spotlight importer",
                risk: risk,
                confidence: .low,
                minimumBytes: minimumBytes,
                usesRelatedNameMatch: true,
                detail: pluginDetail
            ),
            AppTraceLeftoverLocation(
                directory: baseDirectory.appendingPathComponent("PreferencePanes", isDirectory: true),
                label: "preference pane",
                risk: risk,
                confidence: .low,
                minimumBytes: minimumBytes,
                usesRelatedNameMatch: true,
                detail: pluginDetail
            ),
            AppTraceLeftoverLocation(
                directory: baseDirectory.appendingPathComponent("Screen Savers", isDirectory: true),
                label: "screen saver",
                risk: risk,
                confidence: .low,
                minimumBytes: minimumBytes,
                usesRelatedNameMatch: true,
                detail: pluginDetail
            )
        ]
    }

    private func systemAppTraceLocations(
        appSupportMinimum: Int64,
        preferenceMinimum: Int64,
        pluginMinimum: Int64
    ) -> [AppTraceLeftoverLocation] {
        let systemLibrary = URL(fileURLWithPath: "/Library", isDirectory: true)
        let systemDetail = "This is a system-wide app trace. It may affect every user on this Mac, so review it rather than deleting directly."

        var locations = [
            AppTraceLeftoverLocation(
                directory: systemLibrary.appendingPathComponent("Application Support", isDirectory: true),
                label: "system application support folder",
                risk: .high,
                confidence: .low,
                minimumBytes: appSupportMinimum,
                itemKind: .directories,
                usesRelatedNameMatch: true,
                detail: systemDetail
            ),
            AppTraceLeftoverLocation(
                directory: systemLibrary.appendingPathComponent("Preferences", isDirectory: true),
                label: "system preference file",
                risk: .high,
                confidence: .medium,
                minimumBytes: preferenceMinimum,
                itemKind: .files,
                allowedExtensions: ["plist"],
                detail: systemDetail
            ),
            AppTraceLeftoverLocation(
                directory: systemLibrary.appendingPathComponent("Logs", isDirectory: true),
                label: "system log folder",
                risk: .high,
                confidence: .low,
                minimumBytes: config.minimumLogBytes,
                usesRelatedNameMatch: true,
                detail: systemDetail
            ),
            AppTraceLeftoverLocation(
                directory: systemLibrary.appendingPathComponent("Caches", isDirectory: true),
                label: "system cache folder",
                risk: .high,
                confidence: .low,
                minimumBytes: config.minimumCacheBytes,
                usesRelatedNameMatch: true,
                detail: systemDetail
            ),
            AppTraceLeftoverLocation(
                directory: systemLibrary.appendingPathComponent("PrivilegedHelperTools", isDirectory: true),
                label: "privileged helper",
                risk: .high,
                confidence: .medium,
                minimumBytes: 1,
                itemKind: .files,
                detail: "Privileged helpers can run with elevated permissions. Use the vendor uninstaller or inspect carefully before removing them."
            ),
            AppTraceLeftoverLocation(
                directory: URL(fileURLWithPath: "/Users/Shared", isDirectory: true),
                label: "shared app support folder",
                risk: .high,
                confidence: .low,
                minimumBytes: appSupportMinimum,
                itemKind: .directories,
                usesRelatedNameMatch: true,
                detail: "Shared folders can contain assets, libraries, licenses, or data used by multiple user accounts. Review before removing them."
            ),
            AppTraceLeftoverLocation(
                directory: URL(fileURLWithPath: "/var/db/receipts", isDirectory: true),
                label: "package receipt",
                risk: .high,
                confidence: .low,
                minimumBytes: 1,
                requiresStaleDate: false,
                itemKind: .files,
                identityStyle: .packageReceipt,
                allowedExtensions: ["plist"],
                detail: "Package receipts are tiny install records. They are useful evidence of old software, but should be treated as review-only."
            )
        ]

        locations += pluginTraceLocations(
            baseDirectory: systemLibrary,
            risk: .high,
            minimumBytes: pluginMinimum
        )

        return locations
    }

    private func appTraceCandidates(for location: AppTraceLeftoverLocation) -> [URL] {
        switch location.traversal {
        case .immediateChildren:
            return immediateChildren(of: location.directory)
        case .childrenOfImmediateDirectories:
            return immediateChildren(of: location.directory).flatMap { child -> [URL] in
                guard
                    let metadata = fileManager.storageAssistantMetadata(for: child),
                    metadata.isDirectory,
                    !metadata.isSymbolicLink
                else {
                    return []
                }

                return immediateChildren(of: child)
            }
        }
    }

    private func scanLibraryLeftovers(installedApps: InstalledAppInventory) -> [Recommendation] {
        let appSupportMinimum = max(config.minimumLeftoverBytes, 100 * 1_024 * 1_024)
        let preferenceMinimum = min(config.minimumLeftoverBytes, 64 * 1_024)

        let locations = [
            LeftoverLocation(
                directory: homeDirectory.appendingPathComponent("Library/Saved Application State", isDirectory: true),
                label: "saved application state",
                risk: .low,
                confidence: .high,
                action: .moveToTrash,
                minimumBytes: min(1 * 1_024 * 1_024, config.minimumLeftoverBytes),
                requiresStaleDate: false,
                detail: "Saved window/session state is usually disposable, but close related apps before removing it."
            ),
            LeftoverLocation(
                directory: homeDirectory.appendingPathComponent("Library/Preferences", isDirectory: true),
                label: "preference file",
                risk: .medium,
                confidence: .medium,
                action: .moveToTrash,
                minimumBytes: preferenceMinimum,
                requiresStaleDate: true,
                detail: "Preference files are usually small, but this one appears to belong to software that is not currently installed."
            ),
            LeftoverLocation(
                directory: homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true),
                label: "application support folder",
                risk: .medium,
                confidence: .low,
                action: .moveToTrash,
                minimumBytes: appSupportMinimum,
                requiresStaleDate: true,
                detail: "Application Support can contain user data. Review the folder before moving it to Trash."
            )
        ]

        var recommendations: [Recommendation] = []

        for location in locations {
            guard !isCancelled else { return recommendations }
            guard fileManager.storageAssistantFileExists(at: location.directory) else {
                continue
            }

            for url in immediateChildren(of: location.directory) {
                guard !isCancelled else { return recommendations }
                guard
                    let metadata = fileManager.storageAssistantMetadata(for: url),
                    !metadata.isSymbolicLink,
                    !isProtectedLeftoverPath(url)
                else {
                    continue
                }

                let identity = leftoverIdentity(for: url)
                let knownSignature = knownLeftoverSignature(matching: "\(url.path) \(identity)")
                let isBundleIdentifier = isBundleIdentifierCandidate(identity)

                if ["application support folder", "app container", "group container"].contains(location.label),
                   knownSignature == nil,
                   !isBundleIdentifier {
                    continue
                }

                guard shouldFlagLeftover(identity: identity, url: url, installedApps: installedApps) else {
                    continue
                }

                let size = itemSize(url, metadata: metadata)
                let minimumBytes = knownSignature == nil ? location.minimumBytes : 0
                guard size >= minimumBytes else {
                    continue
                }

                if location.requiresStaleDate && knownSignature == nil {
                    let ageDate = latestActivityDate(for: url, metadata: metadata)
                    let ageDays = StorageFormatting.daysSince(ageDate, now: now)
                    guard (ageDays ?? config.leftoverStaleDays) >= config.leftoverStaleDays else {
                        continue
                    }
                }

                let confidence = knownSignature == nil ? location.confidence : .high
                let displayName = knownSignature?.displayName ?? "\(identity) \(location.label)"
                let reason = knownSignature == nil
                    ? "\(location.label.capitalized), \(StorageFormatting.bytes(size)), but no installed app match was found."
                    : "\(knownSignature!.displayName) component found, \(StorageFormatting.bytes(size)), with no obvious installed owner."

                recommendations.append(
                    recommendation(
                        url: url,
                        metadata: metadata,
                        displayName: displayName,
                        category: .leftovers,
                        risk: knownSignature == nil ? location.risk : maxRisk(location.risk, .medium),
                        confidence: confidence,
                        sizeBytes: size,
                        reason: reason,
                        detail: knownSignature?.detail ?? location.detail,
                        defaultAction: knownSignature == nil ? location.action : .revealOnly
                    )
                )
            }
        }

        return recommendations
    }

    private func scanLaunchServiceLeftovers(
        installedApps: InstalledAppInventory,
        runningProcesses: RunningProcessInventory
    ) -> [Recommendation] {
        let launchDirectories: [(url: URL, kind: String, risk: RiskLevel)] = [
            (homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true), "launch agent", .medium),
            (URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true), "launch agent", .high),
            (URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true), "launch daemon", .high)
        ]

        var recommendations: [Recommendation] = []

        for directory in launchDirectories {
            guard !isCancelled else { return recommendations }
            guard fileManager.storageAssistantFileExists(at: directory.url) else {
                continue
            }

            for url in immediateChildren(of: directory.url) where url.pathExtension == "plist" {
                guard !isCancelled else { return recommendations }
                guard let metadata = fileManager.storageAssistantMetadata(for: url) else {
                    continue
                }

                let service = readLaunchService(at: url)
                let label = service.label
                guard !isProtectedBundleIdentifier(label) else {
                    continue
                }

                let programExists = service.program.map { fileManager.fileExists(atPath: $0) } ?? true
                let knownSignature = knownLeftoverSignature(matching: service.searchableText)
                let relatedAppInstalled = knownSignature?.hasInstalledRelatedApp(in: installedApps) ?? false
                let running = isLaunchServiceRunning(service, runningProcesses: runningProcesses)
                let installedMatch = installedApps.containsBundleIdentifierLike(label)

                guard knownSignature != nil || !programExists || (!installedMatch && isBundleIdentifierCandidate(label) && running) else {
                    continue
                }

                let size = itemSize(url, metadata: metadata)
                let displayName = knownSignature.map { "\($0.displayName) \(directory.kind)" } ??
                    "\(label) \(directory.kind)"
                let runningText = running ? " It appears to be running." : ""
                let ownerText = relatedAppInstalled
                    ? " A related app appears to be installed, so review before changing it."
                    : " No related installed app was found."
                let reason: String

                if !programExists {
                    reason = "Launch item points to a missing program.\(ownerText)\(runningText)"
                } else if knownSignature != nil {
                    reason = "\(knownSignature!.displayName) background component found.\(ownerText)\(runningText)"
                } else {
                    reason = "Background service appears to be running, but no installed app with a matching bundle identifier was found."
                }

                recommendations.append(
                    recommendation(
                        url: url,
                        metadata: metadata,
                        displayName: displayName,
                        category: .leftovers,
                        risk: directory.risk,
                        confidence: knownSignature == nil ? .medium : .high,
                        sizeBytes: size,
                        reason: reason,
                        detail: launchServiceDetail(for: knownSignature, isRunning: running),
                        defaultAction: .revealOnly
                    )
                )
            }
        }

        return recommendations
    }

    private func scanKnownServiceLeftovers(
        installedApps: InstalledAppInventory,
        runningProcesses: RunningProcessInventory
    ) -> [Recommendation] {
        let knownPaths = [
            URL(fileURLWithPath: "/Library/Application Support/PACE Anti-Piracy", isDirectory: true),
            URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.paceap.eden.licensed"),
            URL(fileURLWithPath: "/Library/Frameworks/PACEEdenExperience.framework", isDirectory: true),
            URL(fileURLWithPath: "/Library/Extensions/PACESupportFamily.kext", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Application Support/iLok License Manager", isDirectory: true)
        ]

        var recommendations: [Recommendation] = []

        for url in knownPaths {
            guard !isCancelled else { return recommendations }
            guard
                fileManager.storageAssistantFileExists(at: url),
                let metadata = fileManager.storageAssistantMetadata(for: url),
                let signature = knownLeftoverSignature(matching: url.path)
            else {
                continue
            }

            let size = itemSize(url, metadata: metadata)
            let installedRelatedApp = signature.hasInstalledRelatedApp(in: installedApps)
            let running = runningProcesses.containsAny(signature.keywords + [url.lastPathComponent])
            let ownerText = installedRelatedApp
                ? "A related app appears to be installed."
                : "No related installed app was found."
            let runningText = running ? " A related process appears to be running." : ""

            recommendations.append(
                recommendation(
                    url: url,
                    metadata: metadata,
                    displayName: signature.displayName,
                    category: .leftovers,
                    risk: url.path.hasPrefix(homeDirectory.path) ? .medium : .high,
                    confidence: .high,
                    sizeBytes: size,
                    reason: "\(signature.displayName) component found. \(ownerText)\(runningText)",
                    detail: signature.detail,
                    defaultAction: .revealOnly
                )
            )
        }

        return recommendations
    }

    private func scanSystemDataBreakdown() -> SystemDataBreakdown {
        var entries: [SystemDataEntry] = []
        var staleItems: [SystemDataStaleItem] = []
        var notes = [
            "Apple does not expose an exact public breakdown for System Data. This lens measures visible folders that commonly contribute to it; protected system files, purgeable space, and some APFS accounting may not be included."
        ]

        for candidate in systemDataCandidates() {
            guard !isCancelled else {
                return SystemDataBreakdown(entries: entries, notes: notes)
            }

            guard
                fileManager.storageAssistantFileExists(at: candidate.url),
                let metadata = fileManager.storageAssistantMetadata(for: candidate.url),
                !metadata.isSymbolicLink
            else {
                continue
            }

            report("Measuring \(candidate.title)", url: candidate.url)
            let measurement = systemDataMeasurement(for: candidate, metadata: metadata)
            guard measurement.sizeBytes > 0 || !measurement.contributors.isEmpty else {
                continue
            }

            entries.append(
                SystemDataEntry(
                    title: candidate.title,
                    category: candidate.category,
                    path: candidate.url.path,
                    sizeBytes: measurement.sizeBytes,
                    detail: candidate.detail,
                    contributors: measurement.contributors
                )
            )
            staleItems += measurement.staleItems
        }

        if scansRealStartupVolume {
            switch localSnapshotSummary() {
            case .some(let summary) where summary.count > 0:
                if let totalBytes = summary.totalBytes, totalBytes > 0 {
                    entries.append(
                        SystemDataEntry(
                            title: "Local Time Machine snapshots",
                            category: .localSnapshots,
                            path: nil,
                            sizeBytes: totalBytes,
                            detail: "APFS local snapshots are system-managed restore points. They can be large but are usually purgeable by macOS when space is needed."
                        )
                    )
                } else {
                    notes.append("Found \(summary.count) local Time Machine snapshot\(summary.count == 1 ? "" : "s"), but macOS did not report their sizes.")
                }
            default:
                break
            }
        }

        return SystemDataBreakdown(
            entries: entries.sorted {
                ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1)
            },
            notes: notes,
            staleItems: deduplicateSystemDataStaleItems(staleItems)
        )
    }

    private func systemDataCandidates() -> [SystemDataCandidate] {
        let userLibrary = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        var candidates = [
            SystemDataCandidate(
                url: userLibrary.appendingPathComponent("Application Support", isDirectory: true),
                title: "User Application Support",
                category: .userLibrary,
                detail: "App databases, indexes, assets, and local support files. This is often one of the largest visible parts of Apple's System Data bucket."
            ),
            SystemDataCandidate(
                url: userLibrary.appendingPathComponent("Containers", isDirectory: true),
                title: "Sandboxed app containers",
                category: .appContainers,
                detail: "Per-app sandbox data, including caches, databases, and documents stored inside app containers."
            ),
            SystemDataCandidate(
                url: userLibrary.appendingPathComponent("Group Containers", isDirectory: true),
                title: "Shared app containers",
                category: .appContainers,
                detail: "Data shared between apps from the same developer, such as browser profiles, mail state, sync databases, and helper app data."
            ),
            SystemDataCandidate(
                url: userLibrary.appendingPathComponent("Caches", isDirectory: true),
                title: "User caches",
                category: .cachesAndLogs,
                detail: "Rebuildable app caches in your user Library. Storage Assistant also surfaces older large cache folders as cleanup recommendations."
            ),
            SystemDataCandidate(
                url: userLibrary.appendingPathComponent("Logs", isDirectory: true),
                title: "User logs",
                category: .cachesAndLogs,
                detail: "Application logs and diagnostics in your user Library."
            ),
            SystemDataCandidate(
                url: userLibrary.appendingPathComponent("Developer", isDirectory: true),
                title: "Developer support data",
                category: .developerSupport,
                detail: "Xcode, simulator, device support, archives, and other developer-tool support data."
            )
        ]

        guard config.includeSystemAppTraceScan else {
            return candidates
        }

        candidates += [
            SystemDataCandidate(
                url: URL(fileURLWithPath: "/Library/Application Support", isDirectory: true),
                title: "System-wide Application Support",
                category: .systemLibrary,
                detail: "Machine-wide support files, assets, frameworks, databases, and vendor data available to every user on this Mac."
            ),
            SystemDataCandidate(
                url: URL(fileURLWithPath: "/Library/Caches", isDirectory: true),
                title: "System-wide caches",
                category: .cachesAndLogs,
                detail: "Machine-wide caches. These are system-scoped and should be inspected rather than removed directly."
            ),
            SystemDataCandidate(
                url: URL(fileURLWithPath: "/Library/Logs", isDirectory: true),
                title: "System-wide logs",
                category: .cachesAndLogs,
                detail: "Machine-wide logs and diagnostic output."
            ),
            SystemDataCandidate(
                url: URL(fileURLWithPath: "/Library/Developer", isDirectory: true),
                title: "System-wide developer data",
                category: .developerSupport,
                detail: "Developer tooling installed at the system level, including command line tool support and shared device data."
            ),
            SystemDataCandidate(
                url: URL(fileURLWithPath: "/Users/Shared", isDirectory: true),
                title: "Shared user storage",
                category: .systemLibrary,
                detail: "Shared assets and support folders visible to all local users."
            ),
            SystemDataCandidate(
                url: URL(fileURLWithPath: "/private/var/folders", isDirectory: true),
                title: "Per-user temporary system folders",
                category: .temporaryStorage,
                detail: "macOS-managed temporary files and per-user caches. These usually clear over time and are not a direct deletion target."
            ),
            SystemDataCandidate(
                url: URL(fileURLWithPath: "/private/var/tmp", isDirectory: true),
                title: "System temporary folder",
                category: .temporaryStorage,
                detail: "Temporary files used by macOS and command-line tools."
            ),
            SystemDataCandidate(
                url: URL(fileURLWithPath: "/private/var/vm", isDirectory: true),
                title: "Swap and sleep files",
                category: .virtualMemory,
                detail: "Virtual memory swap files and sleep images managed by macOS. Their size changes with memory pressure and sleep behavior."
            )
        ]

        return candidates
    }

    private func systemDataMeasurement(
        for candidate: SystemDataCandidate,
        metadata: FileMetadata
    ) -> SystemDataMeasurement {
        let url = candidate.url
        guard metadata.isDirectory else {
            return SystemDataMeasurement(
                sizeBytes: metadata.allocatedSize,
                contributors: [],
                staleItems: []
            )
        }

        var total: Int64 = 0
        var contributors: [SystemDataContributor] = []
        var staleItems: [SystemDataStaleItem] = []

        for child in immediateChildren(of: url) {
            guard !isCancelled else { break }
            guard
                let childMetadata = fileManager.storageAssistantMetadata(for: child),
                !childMetadata.isSymbolicLink
            else {
                continue
            }

            let size = itemSize(child, metadata: childMetadata)
            total += size

            if size > 0 {
                contributors.append(
                    SystemDataContributor(
                        path: child.path,
                        displayName: child.lastPathComponent,
                        sizeBytes: size
                    )
                )
            }

            if let staleItem = systemDataStaleItem(
                candidate: candidate,
                url: child,
                metadata: childMetadata,
                sizeBytes: size
            ) {
                staleItems.append(staleItem)
            }
        }

        return SystemDataMeasurement(
            sizeBytes: total,
            contributors: contributors
                .sorted { $0.sizeBytes > $1.sizeBytes }
                .prefix(8)
                .map { $0 },
            staleItems: staleItems
        )
    }

    private func systemDataStaleItem(
        candidate: SystemDataCandidate,
        url: URL,
        metadata: FileMetadata,
        sizeBytes: Int64
    ) -> SystemDataStaleItem? {
        guard sizeBytes >= minimumSystemDataStaleBytes(for: candidate) else {
            return nil
        }

        guard let lastUsedDate = latestActivityDate(for: url, metadata: metadata) else {
            return nil
        }

        guard let staleDays = staleDays(for: candidate) else {
            return nil
        }

        guard (StorageFormatting.daysSince(lastUsedDate, now: now) ?? 0) >= staleDays else {
            return nil
        }

        let safety = systemDataSafety(for: candidate, url: url)
        let agePhrase = StorageFormatting.agePhrase(for: lastUsedDate, now: now)
        return SystemDataStaleItem(
            path: url.path,
            displayName: url.lastPathComponent,
            category: candidate.category,
            recommendationCategory: safety.recommendationCategory,
            risk: safety.risk,
            confidence: safety.confidence,
            sizeBytes: sizeBytes,
            createdDate: metadata.createdDate,
            modifiedDate: metadata.modifiedDate,
            accessedDate: metadata.accessedDate,
            lastUsedDate: lastUsedDate,
            reason: "\(StorageFormatting.bytes(sizeBytes)) in \(candidate.title), last used or changed \(agePhrase).",
            detail: safety.detail,
            defaultAction: safety.action
        )
    }

    private func systemDataReviewRecommendations(from items: [SystemDataStaleItem]) -> [Recommendation] {
        items.compactMap { item in
            let path = item.path
            guard !item.canMoveToTrash,
                  ![RecommendationCategory.caches, .logs].contains(item.recommendationCategory),
                  !path.contains("/Library/Caches/"),
                  !path.contains("/Library/Logs/"),
                  !(config.enableAppLeftoverScan && isApplicationSupportReviewPath(path)) else {
                return nil
            }

            return Recommendation(
                path: item.path,
                displayName: item.displayName,
                category: .leftovers,
                risk: item.risk,
                confidence: item.confidence,
                sizeBytes: item.sizeBytes,
                createdDate: item.createdDate,
                modifiedDate: item.modifiedDate,
                accessedDate: item.accessedDate,
                reason: item.reason,
                detail: item.detail,
                defaultAction: item.defaultAction
            )
        }
    }

    private func isApplicationSupportReviewPath(_ path: String) -> Bool {
        let userApplicationSupport = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .path

        return path.hasPrefix(userApplicationSupport + "/") ||
            path.hasPrefix("/Library/Application Support/") ||
            path.hasPrefix("/Users/Shared/")
    }

    private func minimumSystemDataStaleBytes(for candidate: SystemDataCandidate) -> Int64 {
        switch candidate.category {
        case .cachesAndLogs:
            if candidate.url.lastPathComponent.localizedCaseInsensitiveContains("Logs") {
                return config.minimumLogBytes
            }
            return config.minimumCacheBytes
        case .temporaryStorage:
            return min(config.minimumCacheBytes, 50 * 1_024 * 1_024)
        case .virtualMemory, .localSnapshots:
            return Int64.max
        case .developerSupport:
            return config.minimumDeveloperArtifactBytes
        case .userLibrary, .appContainers, .systemLibrary:
            return max(config.minimumLeftoverBytes, 10 * 1_024 * 1_024)
        }
    }

    private func staleDays(for candidate: SystemDataCandidate) -> Int? {
        switch candidate.category {
        case .cachesAndLogs:
            return candidate.url.lastPathComponent.localizedCaseInsensitiveContains("Logs")
                ? config.oldLogDays
                : config.oldCacheDays
        case .temporaryStorage:
            return min(max(config.oldCacheDays, 7), 30)
        case .developerSupport, .userLibrary, .appContainers, .systemLibrary:
            return config.leftoverStaleDays
        case .virtualMemory, .localSnapshots:
            return nil
        }
    }

    private func systemDataSafety(
        for candidate: SystemDataCandidate,
        url: URL
    ) -> (
        risk: RiskLevel,
        confidence: ConfidenceLevel,
        action: CleanupAction,
        recommendationCategory: RecommendationCategory,
        detail: String
    ) {
        let path = url.path
        let userCacheRoot = homeDirectory.appendingPathComponent("Library/Caches", isDirectory: true).path
        let userLogRoot = homeDirectory.appendingPathComponent("Library/Logs", isDirectory: true).path

        if path.hasPrefix(userCacheRoot + "/") {
            return (
                .low,
                .high,
                .moveToTrash,
                .caches,
                "User cache folders are normally rebuildable. Quit the related app before moving the folder to Trash."
            )
        }

        if path.hasPrefix(userLogRoot + "/") {
            return (
                .low,
                .high,
                .moveToTrash,
                .logs,
                "Old user logs are normally disposable once you no longer need them for troubleshooting."
            )
        }

        if path.hasPrefix("/Library/Caches/") {
            return (
                .high,
                .low,
                .revealOnly,
                .caches,
                "This is a system-wide cache. Inspect it or use the vendor's cleanup tools rather than deleting it directly."
            )
        }

        if path.hasPrefix("/Library/Logs/") {
            return (
                .high,
                .low,
                .revealOnly,
                .logs,
                "This is a system-wide log folder. Review it before removing anything because it may affect every user on this Mac."
            )
        }

        if path.hasPrefix("/private/var/") {
            return (
                .medium,
                .low,
                .revealOnly,
                .leftovers,
                "This is macOS-managed temporary or runtime storage. It may clear by itself; review before manually removing files."
            )
        }

        if path.contains("/Developer/") || path.contains("/CoreSimulator") || path.contains("/Xcode") {
            return (
                .medium,
                .medium,
                .revealOnly,
                .xcode,
                "Developer support data can include simulators, archives, and device support. Prefer Xcode or command-line cleanup tools when available."
            )
        }

        return (
            candidate.category == .systemLibrary ? .high : .medium,
            .low,
            .revealOnly,
            .leftovers,
            "This may be app support data rather than disposable cache. Reveal it and confirm the owning app or service before removing it."
        )
    }

    private func systemDataCategory(
        for url: URL,
        recommendationCategory: RecommendationCategory
    ) -> SystemDataCategory {
        let path = url.path

        if path.contains("/Caches/") || path.contains("/Logs/") {
            return .cachesAndLogs
        }

        if path.contains("/Containers/") || path.contains("/Group Containers/") {
            return .appContainers
        }

        if path.contains("/Developer/") ||
            path.contains("/CoreSimulator") ||
            [.xcode, .unity, .docker, .python, .node, .homebrew, .buildArtifacts].contains(recommendationCategory) {
            return .developerSupport
        }

        if path.hasPrefix("/private/var/vm/") {
            return .virtualMemory
        }

        if path.hasPrefix("/private/var/") {
            return .temporaryStorage
        }

        if path.hasPrefix("/Library/") || path.hasPrefix("/Users/Shared/") {
            return .systemLibrary
        }

        return .userLibrary
    }

    private func isLikelySystemDataPath(_ path: String) -> Bool {
        let homePath = homeDirectory.path
        let userLibraryPath = homeDirectory.appendingPathComponent("Library", isDirectory: true).path
        let hiddenDeveloperCachePrefixes = [
            ".cache",
            ".gradle",
            ".m2",
            ".npm",
            ".pub-cache",
            ".rustup",
            ".swiftpm"
        ].map { "\(homePath)/\($0)" }

        return path.hasPrefix(userLibraryPath + "/") ||
            path.hasPrefix("/Library/") ||
            path.hasPrefix("/Users/Shared/") ||
            path.hasPrefix("/private/var/") ||
            hiddenDeveloperCachePrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func latestDate(_ dates: [Date?]) -> Date? {
        dates.compactMap { $0 }.max()
    }

    private func deduplicateSystemDataStaleItems(_ items: [SystemDataStaleItem]) -> [SystemDataStaleItem] {
        var bestByPath: [String: SystemDataStaleItem] = [:]

        for item in items {
            let canonicalPath = URL(fileURLWithPath: item.path)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path

            guard let existing = bestByPath[canonicalPath] else {
                bestByPath[canonicalPath] = item
                continue
            }

            if systemDataStaleItemScore(item) > systemDataStaleItemScore(existing) {
                bestByPath[canonicalPath] = item
            }
        }

        return Array(bestByPath.values).sorted {
            if $0.canMoveToTrash != $1.canMoveToTrash {
                return $0.canMoveToTrash
            }
            return $0.sizeBytes > $1.sizeBytes
        }
    }

    private func systemDataStaleItemScore(_ item: SystemDataStaleItem) -> Int {
        var score = item.canMoveToTrash ? 10 : 0
        switch item.confidence {
        case .high: score += 3
        case .medium: score += 2
        case .low: score += 1
        }
        score -= riskSortValue(item.risk)
        return score
    }

    private var scansRealStartupVolume: Bool {
        homeDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path ==
            FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func localSnapshotSummary() -> LocalSnapshotSummary? {
        if let summary = diskutilSnapshotSummary() {
            return summary
        }

        return tmutilSnapshotSummary()
    }

    private func diskutilSnapshotSummary() -> LocalSnapshotSummary? {
        guard let data = commandOutput(
            executable: "/usr/sbin/diskutil",
            arguments: ["apfs", "listSnapshots", "/", "-plist"]
        ) else {
            return nil
        }

        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        else {
            return nil
        }

        let snapshots = plist["Snapshots"] as? [[String: Any]] ??
            plist["APFSSnapshots"] as? [[String: Any]] ??
            []
        guard !snapshots.isEmpty else {
            return nil
        }

        var total: Int64 = 0
        var hasSizes = false
        let names = snapshots.compactMap { snapshot -> String? in
            snapshot["SnapshotName"] as? String ??
                snapshot["Name"] as? String
        }

        for snapshot in snapshots {
            guard let size = snapshotSize(snapshot) else {
                continue
            }
            total += size
            hasSizes = true
        }

        return LocalSnapshotSummary(
            count: snapshots.count,
            totalBytes: hasSizes ? total : nil,
            names: names
        )
    }

    private func tmutilSnapshotSummary() -> LocalSnapshotSummary? {
        guard let data = commandOutput(
            executable: "/usr/bin/tmutil",
            arguments: ["listlocalsnapshots", "/"]
        ) else {
            return nil
        }

        let names = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !names.isEmpty else {
            return nil
        }

        return LocalSnapshotSummary(
            count: names.count,
            totalBytes: nil,
            names: names
        )
    }

    private func snapshotSize(_ snapshot: [String: Any]) -> Int64? {
        for key in ["Size", "SnapshotSize", "PurgeableSize", "CapacityInUse"] {
            if let value = snapshot[key] as? NSNumber {
                return value.int64Value
            }

            if let value = snapshot[key] as? String,
               let bytes = Int64(value) {
                return bytes
            }
        }

        return nil
    }

    private func commandOutput(executable: String, arguments: [String]) -> Data? {
        guard fileManager.isExecutableFile(atPath: executable) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        return outputPipe.fileHandleForReading.readDataToEndOfFile()
    }

    private func leftoverIdentity(for url: URL) -> String {
        let name = url.lastPathComponent

        if name.hasSuffix(".savedState") {
            return String(name.dropLast(".savedState".count))
        }

        if url.pathExtension == "plist" {
            return url.deletingPathExtension().lastPathComponent
        }

        return url.deletingPathExtension().lastPathComponent
    }

    private func homeConfigurationIdentity(for url: URL) -> String {
        let name = url.lastPathComponent

        if name.hasPrefix(".") {
            return String(name.dropFirst())
        }

        return name
    }

    private func appTraceIdentity(for url: URL, style: AppTraceIdentityStyle) -> String? {
        switch style {
        case .standard:
            return leftoverIdentity(for: url)
        case .byHostPreference:
            return byHostPreferenceIdentity(for: url)
        case .groupContainer:
            return groupContainerIdentity(for: url)
        case .cookie:
            return cookieIdentity(for: url)
        case .packageReceipt:
            return packageReceiptIdentity(for: url)
        }
    }

    private func byHostPreferenceIdentity(for url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: ".").map(String.init)
        guard parts.count > 1 else { return name }

        let hostPart = parts.last ?? ""
        let hostCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        if hostPart.count >= 8,
           hostPart.rangeOfCharacter(from: hostCharacters.inverted) == nil {
            return parts.dropLast().joined(separator: ".")
        }

        return name
    }

    private func groupContainerIdentity(for url: URL) -> String? {
        let name = url.lastPathComponent
        if name.hasPrefix("group.") {
            return String(name.dropFirst("group.".count))
        }

        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        if parts.count == 2, isLikelyTeamIdentifier(parts[0]) {
            return parts[1]
        }

        return name
    }

    private func cookieIdentity(for url: URL) -> String? {
        let name = url.lastPathComponent
        let lowercased = name.lowercased()

        if lowercased == "cookies.binarycookies" || lowercased == "cookies.cookies" {
            return nil
        }

        if lowercased.hasSuffix(".binarycookies") {
            return String(name.dropLast(".binarycookies".count))
        }

        if lowercased.hasSuffix(".cookies") {
            return String(name.dropLast(".cookies".count))
        }

        return url.deletingPathExtension().lastPathComponent
    }

    private func packageReceiptIdentity(for url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard !name.isEmpty else { return nil }
        return name
    }

    private func isLikelyTeamIdentifier(_ text: String) -> Bool {
        guard text.count == 10 else { return false }
        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return text.rangeOfCharacter(from: allowedCharacters.inverted) == nil
    }

    private func shouldFlagLeftover(
        identity: String,
        url: URL,
        installedApps: InstalledAppInventory
    ) -> Bool {
        if isProtectedBundleIdentifier(identity) {
            return false
        }

        if knownLeftoverSignature(matching: "\(identity) \(url.path)") != nil {
            return true
        }

        if isBundleIdentifierCandidate(identity) {
            return !installedApps.containsBundleIdentifierLike(identity)
        }

        let normalized = normalizedAppToken(identity)
        guard normalized.count >= 3 else {
            return false
        }

        return !installedApps.containsNameLike(identity)
    }

    private func isBundleIdentifierCandidate(_ text: String) -> Bool {
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return text.contains(".") &&
            text.rangeOfCharacter(from: allowedCharacters.inverted) == nil
    }

    private func isProtectedBundleIdentifier(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let protectedPrefixes = [
            "com.apple.",
            "group.com.apple.",
            "systemgroup.com.apple."
        ]

        return protectedPrefixes.contains { lowercased.hasPrefix($0) }
    }

    private func isProtectedLeftoverPath(_ url: URL) -> Bool {
        let path = url.path
        let lowercasedName = url.lastPathComponent.lowercased()

        if path.hasPrefix(homeDirectory.appendingPathComponent("Library/Application Support/Storage Assistant").path) {
            return true
        }

        let protectedNames: Set<String> = [
            "addressbook",
            "apple",
            "callhistorydb",
            "cloudDocs".lowercased(),
            "com.apple.tcc",
            "crashreporter",
            "dock",
            "knowledge",
            "mails",
            "messages",
            "mobilesync",
            "syncservices"
        ]

        return protectedNames.contains(lowercasedName) ||
            lowercasedName.hasPrefix("com.apple.") ||
            lowercasedName.hasPrefix("group.com.apple.") ||
            lowercasedName.hasPrefix("systemgroup.com.apple.")
    }

    private func isProtectedHomeConfigurationName(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        let protectedPrefixes = [
            ".bash",
            ".zsh",
            ".profile"
        ]
        let protectedNames: Set<String> = [
            ".android",
            ".ansible",
            ".asdf",
            ".aws",
            ".azure",
            ".cache",
            ".cargo",
            ".codex",
            ".config",
            ".cups",
            ".docker",
            ".gem",
            ".git",
            ".gitconfig",
            ".gnupg",
            ".gradle",
            ".kube",
            ".lesshst",
            ".local",
            ".m2",
            ".npm",
            ".nvm",
            ".ollama",
            ".pub-cache",
            ".pyenv",
            ".rbenv",
            ".rustup",
            ".sdkman",
            ".ssh",
            ".swiftpm",
            ".terraform.d",
            ".trash",
            "git",
            "gnupg",
            "ssh",
            "zsh"
        ]

        return protectedNames.contains(lowercased) ||
            protectedPrefixes.contains { lowercased.hasPrefix($0) }
    }

    private func knownLeftoverSignature(matching text: String) -> KnownLeftoverSignature? {
        knownLeftoverSignatures.first { $0.matches(text) }
    }

    private var knownLeftoverSignatures: [KnownLeftoverSignature] {
        [
            KnownLeftoverSignature(
                displayName: "PACE/iLok licensing service",
                keywords: [
                    "paceap",
                    "pace anti-piracy",
                    "ilok",
                    "interlok",
                    "eden.licensed",
                    "pacesupportfamily",
                    "paceeden"
                ],
                relatedAppNames: [
                    "iLok License Manager",
                    "PACE License Support"
                ],
                relatedBundlePrefixes: [
                    "com.paceap",
                    "com.ilok"
                ],
                detail: "PACE/iLok components are licensing services used by some audio software. If you no longer use that software, remove them with the vendor uninstaller or unload the launch daemon before deleting anything manually."
            )
        ]
    }

    private func readLaunchService(at url: URL) -> LaunchService {
        let labelFallback = url.deletingPathExtension().lastPathComponent
        guard
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        else {
            return LaunchService(url: url, label: labelFallback, program: nil, arguments: [])
        }

        let label = plist["Label"] as? String ?? labelFallback
        let program = plist["Program"] as? String
        let arguments = plist["ProgramArguments"] as? [String] ?? []

        return LaunchService(url: url, label: label, program: program, arguments: arguments)
    }

    private func isLaunchServiceRunning(
        _ service: LaunchService,
        runningProcesses: RunningProcessInventory
    ) -> Bool {
        let executableTerms = [
            service.program,
            service.program.map { URL(fileURLWithPath: $0).lastPathComponent },
            service.arguments.first,
            service.arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent },
            service.label
        ]
        .compactMap { $0 }

        let knownTerms = knownLeftoverSignature(matching: service.searchableText)?.keywords ?? []
        return runningProcesses.containsAny(executableTerms + knownTerms)
    }

    private func launchServiceDetail(
        for signature: KnownLeftoverSignature?,
        isRunning: Bool
    ) -> String {
        let runningWarning = isRunning
            ? " It appears to be running, so unload or uninstall it before removal."
            : ""

        return (signature?.detail ?? "Launch agents and daemons can start background processes. Review the plist and use launchctl or the vendor uninstaller before removing it.") + runningWarning
    }

    private func maxRisk(_ lhs: RiskLevel, _ rhs: RiskLevel) -> RiskLevel {
        riskSortValue(lhs) >= riskSortValue(rhs) ? lhs : rhs
    }

    private func discoverDeveloperArtifacts() -> DeveloperArtifacts {
        var artifacts = DeveloperArtifacts()
        let roots = developerSearchRoots()

        for root in roots {
            guard !isCancelled else { return artifacts }
            report("Searching project root", url: root)

            walkDirectories(under: root, maxDepth: config.projectSearchDepth) { url, skipChildren in
                if isCancelled {
                    skipChildren = true
                    return
                }

                if isUnityProject(url) {
                    artifacts.unityProjects.insert(url)
                    skipChildren = true
                    return
                }

                if url.lastPathComponent == "node_modules" {
                    artifacts.nodeModules.insert(url)
                    skipChildren = true
                    return
                }

                if isPythonEnvironment(url) {
                    artifacts.pythonEnvironments.insert(url)
                    skipChildren = true
                    return
                }

                if isGenericBuildArtifact(url) {
                    artifacts.buildArtifacts.insert(url)
                    skipChildren = true
                    return
                }
            }
        }

        return artifacts
    }

    private func developerSearchRoots() -> [URL] {
        if let configuredRoots = config.developerSearchRoots {
            var seen: Set<String> = []
            return configuredRoots
                .filter { fileManager.storageAssistantFileExists(at: $0) }
                .filter { seen.insert($0.standardizedFileURL.path).inserted }
        }

        let names = [
            "Developer",
            "Projects",
            "Code",
            "Workspace",
            "Work",
            "Unity",
            "Unity Projects",
            "Documents",
            "Desktop"
        ]

        var seen: Set<String> = []
        return names
            .map { homeDirectory.appendingPathComponent($0, isDirectory: true) }
            .filter { fileManager.storageAssistantFileExists(at: $0) }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func walkDirectories(
        under root: URL,
        maxDepth: Int,
        visit: (URL, inout Bool) -> Void
    ) {
        guard fileManager.storageAssistantFileExists(at: root) else {
            return
        }

        var stack: [(url: URL, depth: Int)] = [(root, 0)]
        let skipNames: Set<String> = [
            ".git",
            ".svn",
            ".hg",
            ".build",
            ".swiftpm",
            "DerivedData",
            "Library",
            "Temp",
            "Build",
            "Builds",
            "Pods",
            "vendor"
        ]

        while let item = stack.popLast() {
            guard !isCancelled else { return }

            guard
                let metadata = fileManager.storageAssistantMetadata(for: item.url),
                metadata.isDirectory,
                !metadata.isSymbolicLink
            else {
                continue
            }

            var skipChildren = false
            visit(item.url, &skipChildren)

            guard !skipChildren, item.depth < maxDepth else {
                continue
            }

            let children = immediateChildren(of: item.url)
            for child in children {
                let name = child.lastPathComponent

                guard
                    let childMetadata = fileManager.storageAssistantMetadata(for: child),
                    childMetadata.isDirectory,
                    !childMetadata.isSymbolicLink
                else {
                    continue
                }

                var skipChildSubtree = false
                visit(child, &skipChildSubtree)
                if skipChildSubtree || skipNames.contains(name) {
                    continue
                }

                stack.append((child, item.depth + 1))
            }
        }
    }

    private func isUnityProject(_ url: URL) -> Bool {
        let assets = url.appendingPathComponent("Assets", isDirectory: true)
        let projectVersion = url.appendingPathComponent("ProjectSettings/ProjectVersion.txt")
        return fileManager.storageAssistantFileExists(at: assets) &&
            fileManager.storageAssistantFileExists(at: projectVersion)
    }

    private func unityProjectVersion(for project: URL) -> String? {
        let url = project.appendingPathComponent("ProjectSettings/ProjectVersion.txt")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let prefix = "m_EditorVersion:"
        return contents
            .split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }
            .map { line in
                line
                    .replacingOccurrences(of: prefix, with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
    }

    private func isPythonEnvironment(_ url: URL) -> Bool {
        let allowedNames: Set<String> = [".venv", "venv", "env"]
        guard allowedNames.contains(url.lastPathComponent) else {
            return false
        }

        return fileManager.storageAssistantFileExists(
            at: url.appendingPathComponent("pyvenv.cfg")
        )
    }

    private func isGenericBuildArtifact(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let exactNames: Set<String> = [
            ".build",
            "build",
            "dist",
            "target",
            ".gradle",
            ".tox",
            ".next",
            ".nuxt",
            ".dart_tool",
            ".pytest_cache",
            ".mypy_cache",
            ".ruff_cache",
            "coverage",
            "cmake-build-debug",
            "cmake-build-release",
            "deriveddata",
            "pods"
        ]

        guard exactNames.contains(name) else {
            return false
        }

        return true
    }

    private func containsCurrentExecutable(_ url: URL) -> Bool {
        guard let executableURL = Bundle.main.executableURL else {
            return false
        }

        let directoryPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let executablePath = executableURL.standardizedFileURL.resolvingSymlinksInPath().path
        return executablePath == directoryPath || executablePath.hasPrefix(directoryPath + "/")
    }

    private func immediateChildren(of directory: URL) -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .fileAllocatedSizeKey,
                    .totalFileAllocatedSizeKey,
                    .creationDateKey,
                    .contentModificationDateKey,
                    .contentAccessDateKey
                ],
                options: [.skipsPackageDescendants]
            )
        } catch {
            recordDiagnostic(
                path: directory.path,
                kind: .notReadable,
                message: "Could not read \(directory.storageAssistantDisplayPath): \(error.localizedDescription)"
            )
            return []
        }
    }

    private func itemSize(_ url: URL, metadata: FileMetadata) -> Int64 {
        if metadata.isDirectory {
            return directoryMeasurement(for: url).allocatedSize
        }
        return metadata.allocatedSize
    }

    private func latestActivityDate(for url: URL, metadata: FileMetadata) -> Date? {
        let ownActivityDate = latestDate([
            metadata.accessedDate,
            metadata.modifiedDate,
            metadata.createdDate
        ])

        guard metadata.isDirectory else {
            return ownActivityDate
        }

        return latestDate([
            ownActivityDate,
            directoryMeasurement(for: url).latestActivityDate
        ])
    }

    private func directoryMeasurement(for directory: URL) -> DirectoryMeasurement {
        let cacheKey = directory
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        if let measurement = directoryMeasurementCache[cacheKey] {
            return measurement
        }

        let measurement = measureDirectory(directory)
        directoryMeasurementCache[cacheKey] = measurement
        return measurement
    }

    private func measureDirectory(_ directory: URL) -> DirectoryMeasurement {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .contentAccessDateKey
        ]

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { [weak self] url, error in
                self?.recordDiagnostic(
                    path: url.path,
                    kind: .partiallyScanned,
                    message: "Skipped \(url.storageAssistantDisplayPath): \(error.localizedDescription)"
                )
                return true
            }
        ) else {
            recordDiagnostic(
                path: directory.path,
                kind: .notReadable,
                message: "Could not enumerate \(directory.storageAssistantDisplayPath)."
            )
            return DirectoryMeasurement(allocatedSize: 0, latestActivityDate: nil)
        }

        var total: Int64 = 0
        var latestActivityDate: Date?

        for case let url as URL in enumerator {
            guard !isCancelled else {
                enumerator.skipDescendants()
                break
            }

            guard let metadata = fileManager.storageAssistantMetadata(for: url) else {
                continue
            }

            if metadata.isSymbolicLink {
                if metadata.isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            latestActivityDate = latestDate([
                latestActivityDate,
                metadata.accessedDate,
                metadata.modifiedDate,
                metadata.createdDate
            ])

            if metadata.isDirectory {
                continue
            }

            total += metadata.allocatedSize
        }

        return DirectoryMeasurement(
            allocatedSize: total,
            latestActivityDate: latestActivityDate
        )
    }

    private func isLikelyDisposableDownload(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let disposableExtensions: Set<String> = [
            "dmg",
            "iso",
            "pkg",
            "zip",
            "rar",
            "7z",
            "tar",
            "gz",
            "bz2",
            "xz"
        ]

        if disposableExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }

        return name.hasSuffix(".tar.gz") ||
            name.hasSuffix(".tar.bz2") ||
            name.hasSuffix(".tar.xz")
    }

    private func downloadReason(
        url: URL,
        size: Int64,
        ageDate: Date?,
        isDisposableType: Bool,
        isVeryLarge: Bool
    ) -> String {
        var parts: [String] = []

        if isDisposableType {
            parts.append("installer/archive-style download")
        }

        if isVeryLarge {
            parts.append("large item")
        }

        parts.append(StorageFormatting.bytes(size))
        parts.append("last opened/changed \(StorageFormatting.agePhrase(for: ageDate, now: now))")

        return parts.joined(separator: ", ") + "."
    }

    private func recommendation(
        url: URL,
        metadata: FileMetadata,
        displayName: String,
        category: RecommendationCategory,
        risk: RiskLevel,
        confidence: ConfidenceLevel,
        sizeBytes: Int64,
        reason: String,
        detail: String,
        defaultAction: CleanupAction,
        commandSuggestion: CommandSuggestion? = nil
    ) -> Recommendation {
        Recommendation(
            path: url.path,
            displayName: displayName,
            category: category,
            risk: risk,
            confidence: confidence,
            sizeBytes: sizeBytes,
            createdDate: metadata.createdDate,
            modifiedDate: metadata.modifiedDate,
            accessedDate: metadata.accessedDate,
            reason: reason,
            detail: detail,
            defaultAction: defaultAction,
            commandSuggestion: commandSuggestion
        )
    }

    private func riskSortValue(_ risk: RiskLevel) -> Int {
        switch risk {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    private func deduplicateByPath(_ recommendations: [Recommendation]) -> [Recommendation] {
        var bestByPath: [String: Recommendation] = [:]

        for recommendation in recommendations {
            let canonicalPath = URL(fileURLWithPath: recommendation.path)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path

            guard let existing = bestByPath[canonicalPath] else {
                bestByPath[canonicalPath] = recommendation
                continue
            }

            if recommendationSpecificity(recommendation) > recommendationSpecificity(existing) {
                bestByPath[canonicalPath] = recommendation
            }
        }

        return Array(bestByPath.values)
    }

    private func recommendationSpecificity(_ recommendation: Recommendation) -> Int {
        switch recommendation.category {
        case .caches, .logs, .downloads, .trash:
            return 0
        case .unity, .xcode, .docker, .python, .node, .homebrew, .buildArtifacts, .leftovers:
            return 1
        }
    }

    private var isCancelled: Bool {
        shouldCancel()
    }

    private func report(_ message: String, url: URL? = nil) {
        progressHandler?(
            ScanProgress(
                message: message,
                currentPath: url?.storageAssistantDisplayPath
            )
        )
    }

    private func recordDiagnostic(
        path: String,
        kind: PermissionDiagnostic.Kind,
        message: String
    ) {
        let diagnostic = PermissionDiagnostic(path: path, kind: kind, message: message)
        if !diagnostics.contains(where: { $0.id == diagnostic.id }) {
            diagnostics.append(diagnostic)
        }
    }

    private func makeResult(
        _ recommendations: [Recommendation],
        systemDataBreakdown: SystemDataBreakdown? = nil
    ) -> ScanResult {
        ScanResult(
            scanDate: now,
            recommendations: recommendations,
            diagnostics: diagnostics,
            systemDataBreakdown: systemDataBreakdown
        )
    }
}
