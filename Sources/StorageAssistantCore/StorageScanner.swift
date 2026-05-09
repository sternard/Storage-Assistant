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

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let config: ScannerConfig
    private let now: Date
    private let progressHandler: (@Sendable (ScanProgress) -> Void)?
    private let shouldCancel: @Sendable () -> Bool
    private var diagnostics: [PermissionDiagnostic] = []

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

        let sorted = deduplicateByPath(recommendations).sorted {
            if $0.risk != $1.risk {
                return riskSortValue($0.risk) < riskSortValue($1.risk)
            }
            return $0.sizeBytes > $1.sizeBytes
        }

        return makeResult(sorted)
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

            let ageDate = metadata.accessedDate ?? metadata.modifiedDate ?? metadata.createdDate
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

            let ageDays = StorageFormatting.daysSince(metadata.modifiedDate ?? metadata.createdDate, now: now)
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
                reason: "Cache folder, \(StorageFormatting.bytes(size)), last changed \(StorageFormatting.agePhrase(for: metadata.modifiedDate, now: now)).",
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

            let ageDays = StorageFormatting.daysSince(metadata.modifiedDate ?? metadata.createdDate, now: now)
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
                reason: "Log data, \(StorageFormatting.bytes(size)), last changed \(StorageFormatting.agePhrase(for: metadata.modifiedDate, now: now)).",
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

                let ageDate = metadata.modifiedDate ?? metadata.createdDate
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
                    let ageDate = metadata.modifiedDate ?? metadata.createdDate
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
                    let ageDate = metadata.modifiedDate ?? metadata.createdDate
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
            return directoryAllocatedSize(url)
        }
        return metadata.allocatedSize
    }

    private func directoryAllocatedSize(_ directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
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
            return 0
        }

        var total: Int64 = 0

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

            if metadata.isDirectory {
                continue
            }

            total += metadata.allocatedSize
        }

        return total
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

    private func makeResult(_ recommendations: [Recommendation]) -> ScanResult {
        ScanResult(
            scanDate: now,
            recommendations: recommendations,
            diagnostics: diagnostics
        )
    }
}
