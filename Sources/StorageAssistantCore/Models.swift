import Foundation

public enum RiskLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case low
    case medium
    case high

    public var title: String {
        switch self {
        case .low: "Low Risk"
        case .medium: "Review First"
        case .high: "High Risk"
        }
    }
}

public enum ConfidenceLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case high
    case medium
    case low

    public var title: String {
        switch self {
        case .high: "High Confidence"
        case .medium: "Medium Confidence"
        case .low: "Low Confidence"
        }
    }
}

public enum CleanupAction: String, Codable, CaseIterable, Hashable, Sendable {
    case moveToTrash
    case revealOnly
    case commandRecommended

    public var title: String {
        switch self {
        case .moveToTrash: "Move to Trash"
        case .revealOnly: "Review Only"
        case .commandRecommended: "Command Recommended"
        }
    }
}

public struct CommandSuggestion: Codable, Hashable, Sendable {
    public let command: String
    public let reason: String

    public init(command: String, reason: String) {
        self.command = command
        self.reason = reason
    }
}

public enum RecommendationCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case downloads
    case trash
    case caches
    case logs
    case unity
    case xcode
    case docker
    case python
    case node
    case homebrew
    case buildArtifacts
    case leftovers

    public var title: String {
        switch self {
        case .downloads: "Downloads"
        case .trash: "Trash"
        case .caches: "Caches"
        case .logs: "Logs"
        case .unity: "Unity"
        case .xcode: "Xcode"
        case .docker: "Docker"
        case .python: "Python"
        case .node: "Node"
        case .homebrew: "Homebrew"
        case .buildArtifacts: "Build Artifacts"
        case .leftovers: "Leftovers & Services"
        }
    }
}

public struct Recommendation: Identifiable, Codable, Hashable, Sendable {
    public var id: String { ignoreKey }

    public let path: String
    public let displayName: String
    public let category: RecommendationCategory
    public let risk: RiskLevel
    public let confidence: ConfidenceLevel
    public let sizeBytes: Int64
    public let createdDate: Date?
    public let modifiedDate: Date?
    public let accessedDate: Date?
    public let reason: String
    public let detail: String
    public let defaultAction: CleanupAction
    public let commandSuggestion: CommandSuggestion?

    public init(
        path: String,
        displayName: String,
        category: RecommendationCategory,
        risk: RiskLevel,
        confidence: ConfidenceLevel,
        sizeBytes: Int64,
        createdDate: Date?,
        modifiedDate: Date?,
        accessedDate: Date?,
        reason: String,
        detail: String,
        defaultAction: CleanupAction,
        commandSuggestion: CommandSuggestion? = nil
    ) {
        self.path = path
        self.displayName = displayName
        self.category = category
        self.risk = risk
        self.confidence = confidence
        self.sizeBytes = sizeBytes
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
        self.accessedDate = accessedDate
        self.reason = reason
        self.detail = detail
        self.defaultAction = defaultAction
        self.commandSuggestion = commandSuggestion
    }

    public var ignoreKey: String {
        "\(category.rawValue)|\(path)"
    }

    public var canMoveToTrash: Bool {
        defaultAction == .moveToTrash && risk != .high
    }
}

public struct ScanResult: Codable, Hashable, Sendable {
    public let scanDate: Date
    public let recommendations: [Recommendation]
    public let diagnostics: [PermissionDiagnostic]
    public let systemDataBreakdown: SystemDataBreakdown?

    public init(
        scanDate: Date,
        recommendations: [Recommendation],
        diagnostics: [PermissionDiagnostic] = [],
        systemDataBreakdown: SystemDataBreakdown? = nil
    ) {
        self.scanDate = scanDate
        self.recommendations = recommendations
        self.diagnostics = diagnostics
        self.systemDataBreakdown = systemDataBreakdown
    }

    public var totalPotentialBytes: Int64 {
        recommendations.reduce(0) { $0 + $1.sizeBytes }
    }

    public func filtered(ignoredKeys: Set<String>) -> ScanResult {
        ScanResult(
            scanDate: scanDate,
            recommendations: recommendations.filter { !ignoredKeys.contains($0.ignoreKey) },
            diagnostics: diagnostics,
            systemDataBreakdown: systemDataBreakdown?.filtered(ignoredKeys: ignoredKeys)
        )
    }
}

public enum SystemDataCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case userLibrary
    case appContainers
    case cachesAndLogs
    case developerSupport
    case systemLibrary
    case temporaryStorage
    case virtualMemory
    case localSnapshots

    public var title: String {
        switch self {
        case .userLibrary: "User Library"
        case .appContainers: "App Containers"
        case .cachesAndLogs: "Caches & Logs"
        case .developerSupport: "Developer Support"
        case .systemLibrary: "System Library"
        case .temporaryStorage: "Temporary Storage"
        case .virtualMemory: "Virtual Memory"
        case .localSnapshots: "Local Snapshots"
        }
    }
}

public struct SystemDataContributor: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }

    public let path: String
    public let displayName: String
    public let sizeBytes: Int64

    public init(path: String, displayName: String, sizeBytes: Int64) {
        self.path = path
        self.displayName = displayName
        self.sizeBytes = sizeBytes
    }
}

public struct SystemDataStaleItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }

    public let path: String
    public let displayName: String
    public let category: SystemDataCategory
    public let recommendationCategory: RecommendationCategory
    public let risk: RiskLevel
    public let confidence: ConfidenceLevel
    public let sizeBytes: Int64
    public let createdDate: Date?
    public let modifiedDate: Date?
    public let accessedDate: Date?
    public let lastUsedDate: Date?
    public let reason: String
    public let detail: String
    public let defaultAction: CleanupAction

    public init(
        path: String,
        displayName: String,
        category: SystemDataCategory,
        recommendationCategory: RecommendationCategory,
        risk: RiskLevel,
        confidence: ConfidenceLevel,
        sizeBytes: Int64,
        createdDate: Date?,
        modifiedDate: Date?,
        accessedDate: Date?,
        lastUsedDate: Date?,
        reason: String,
        detail: String,
        defaultAction: CleanupAction
    ) {
        self.path = path
        self.displayName = displayName
        self.category = category
        self.recommendationCategory = recommendationCategory
        self.risk = risk
        self.confidence = confidence
        self.sizeBytes = sizeBytes
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
        self.accessedDate = accessedDate
        self.lastUsedDate = lastUsedDate
        self.reason = reason
        self.detail = detail
        self.defaultAction = defaultAction
    }

    public var canMoveToTrash: Bool {
        defaultAction == .moveToTrash && risk != .high
    }

    public var ignoreKey: String {
        "\(recommendationCategory.rawValue)|\(path)"
    }
}

public struct SystemDataEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let category: SystemDataCategory
    public let path: String?
    public let sizeBytes: Int64?
    public let detail: String
    public let contributors: [SystemDataContributor]

    public init(
        id: String? = nil,
        title: String,
        category: SystemDataCategory,
        path: String?,
        sizeBytes: Int64?,
        detail: String,
        contributors: [SystemDataContributor] = []
    ) {
        self.id = id ?? "\(category.rawValue)|\(path ?? title)"
        self.title = title
        self.category = category
        self.path = path
        self.sizeBytes = sizeBytes
        self.detail = detail
        self.contributors = contributors
    }
}

public struct SystemDataBreakdown: Codable, Hashable, Sendable {
    public let entries: [SystemDataEntry]
    public let notes: [String]
    public let staleItems: [SystemDataStaleItem]

    public init(
        entries: [SystemDataEntry],
        notes: [String] = [],
        staleItems: [SystemDataStaleItem] = []
    ) {
        self.entries = entries
        self.notes = notes
        self.staleItems = staleItems
    }

    public var totalKnownBytes: Int64 {
        entries.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
    }

    public func filtered(ignoredKeys: Set<String>) -> SystemDataBreakdown {
        SystemDataBreakdown(
            entries: entries,
            notes: notes,
            staleItems: staleItems.filter { !ignoredKeys.contains($0.ignoreKey) }
        )
    }
}

public struct CleanupHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let originalPath: String
    public let trashedPath: String?
    public let sizeBytes: Int64
    public let category: RecommendationCategory
    public var restoredDate: Date?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        originalPath: String,
        trashedPath: String?,
        sizeBytes: Int64,
        category: RecommendationCategory,
        restoredDate: Date? = nil
    ) {
        self.id = id
        self.date = date
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.sizeBytes = sizeBytes
        self.category = category
        self.restoredDate = restoredDate
    }

    public var canRestoreFromTrash: Bool {
        guard let trashedPath, restoredDate == nil else {
            return false
        }

        return FileManager.default.fileExists(atPath: trashedPath) &&
            !FileManager.default.fileExists(atPath: originalPath)
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var developerScanRootPaths: [String]
    public var projectSearchDepth: Int
    public var thresholds: CleanupThresholds

    public init(
        developerScanRootPaths: [String],
        projectSearchDepth: Int = 5,
        thresholds: CleanupThresholds = .default
    ) {
        self.developerScanRootPaths = developerScanRootPaths
        self.projectSearchDepth = projectSearchDepth
        self.thresholds = thresholds
    }

    public static func defaults(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> AppSettings {
        AppSettings(
            developerScanRootPaths: defaultDeveloperScanRootPaths(
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ),
            projectSearchDepth: 5,
            thresholds: .default
        )
    }

    public static func defaultDeveloperScanRootPaths(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [String] {
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
            .map { homeDirectory.appendingPathComponent($0, isDirectory: true).path }
            .filter { fileManager.fileExists(atPath: $0) }
            .filter { seen.insert(URL(fileURLWithPath: $0).standardizedFileURL.path).inserted }
    }

    public var developerScanRootURLs: [URL] {
        developerScanRootPaths.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
    }

    public func sanitized(fileManager: FileManager = .default) -> AppSettings {
        var seen: Set<String> = []
        let roots = developerScanRootPaths
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { fileManager.fileExists(atPath: $0) }
            .filter { seen.insert(URL(fileURLWithPath: $0).standardizedFileURL.path).inserted }

        return AppSettings(
            developerScanRootPaths: roots,
            projectSearchDepth: min(max(projectSearchDepth, 1), 8),
            thresholds: thresholds.sanitized
        )
    }
}

public struct CleanupThresholds: Codable, Hashable, Sendable {
    public var minimumDownloadBytes: Int64
    public var largeDownloadBytes: Int64
    public var minimumCacheBytes: Int64
    public var minimumLogBytes: Int64
    public var minimumDeveloperArtifactBytes: Int64
    public var minimumLeftoverBytes: Int64
    public var oldDownloadDays: Int
    public var oldCacheDays: Int
    public var oldLogDays: Int
    public var leftoverStaleDays: Int

    public static let `default` = CleanupThresholds(
        minimumDownloadBytes: 100 * 1_024 * 1_024,
        largeDownloadBytes: 1_024 * 1_024 * 1_024,
        minimumCacheBytes: 100 * 1_024 * 1_024,
        minimumLogBytes: 50 * 1_024 * 1_024,
        minimumDeveloperArtifactBytes: 250 * 1_024 * 1_024,
        minimumLeftoverBytes: 10 * 1_024 * 1_024,
        oldDownloadDays: 30,
        oldCacheDays: 30,
        oldLogDays: 14,
        leftoverStaleDays: 90
    )

    public init(
        minimumDownloadBytes: Int64,
        largeDownloadBytes: Int64,
        minimumCacheBytes: Int64,
        minimumLogBytes: Int64,
        minimumDeveloperArtifactBytes: Int64,
        minimumLeftoverBytes: Int64,
        oldDownloadDays: Int,
        oldCacheDays: Int,
        oldLogDays: Int,
        leftoverStaleDays: Int
    ) {
        self.minimumDownloadBytes = minimumDownloadBytes
        self.largeDownloadBytes = largeDownloadBytes
        self.minimumCacheBytes = minimumCacheBytes
        self.minimumLogBytes = minimumLogBytes
        self.minimumDeveloperArtifactBytes = minimumDeveloperArtifactBytes
        self.minimumLeftoverBytes = minimumLeftoverBytes
        self.oldDownloadDays = oldDownloadDays
        self.oldCacheDays = oldCacheDays
        self.oldLogDays = oldLogDays
        self.leftoverStaleDays = leftoverStaleDays
    }

    public var sanitized: CleanupThresholds {
        CleanupThresholds(
            minimumDownloadBytes: clampBytes(minimumDownloadBytes),
            largeDownloadBytes: max(clampBytes(largeDownloadBytes), clampBytes(minimumDownloadBytes)),
            minimumCacheBytes: clampBytes(minimumCacheBytes),
            minimumLogBytes: clampBytes(minimumLogBytes),
            minimumDeveloperArtifactBytes: clampBytes(minimumDeveloperArtifactBytes),
            minimumLeftoverBytes: clampBytes(minimumLeftoverBytes),
            oldDownloadDays: clampDays(oldDownloadDays),
            oldCacheDays: clampDays(oldCacheDays),
            oldLogDays: clampDays(oldLogDays),
            leftoverStaleDays: clampDays(leftoverStaleDays)
        )
    }

    private func clampBytes(_ value: Int64) -> Int64 {
        min(max(value, 0), 100 * 1_024 * 1_024 * 1_024)
    }

    private func clampDays(_ value: Int) -> Int {
        min(max(value, 0), 3650)
    }
}

public struct PermissionDiagnostic: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case missing
        case notReadable
        case partiallyScanned
    }

    public let id: String
    public let path: String
    public let kind: Kind
    public let message: String

    public init(path: String, kind: Kind, message: String) {
        self.id = "\(kind.rawValue)|\(path)"
        self.path = path
        self.kind = kind
        self.message = message
    }
}

public struct ScanSnapshot: Identifiable, Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public let path: String
        public let category: RecommendationCategory
        public let sizeBytes: Int64
        public let risk: RiskLevel
    }

    public let id: UUID
    public let date: Date
    public let entries: [Entry]

    public init(id: UUID = UUID(), date: Date, entries: [Entry]) {
        self.id = id
        self.date = date
        self.entries = entries
    }

    public init(result: ScanResult) {
        self.init(
            date: result.scanDate,
            entries: result.recommendations.map {
                Entry(
                    path: $0.path,
                    category: $0.category,
                    sizeBytes: $0.sizeBytes,
                    risk: $0.risk
                )
            }
        )
    }

    public var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.sizeBytes }
    }
}

public struct GrowthSummary: Hashable, Sendable {
    public let previousSnapshot: ScanSnapshot
    public let latestSnapshot: ScanSnapshot
    public let totalDeltaBytes: Int64

    public init?(snapshots: [ScanSnapshot]) {
        let sorted = snapshots.sorted { $0.date > $1.date }
        guard sorted.count >= 2 else {
            return nil
        }

        self.latestSnapshot = sorted[0]
        self.previousSnapshot = sorted[1]
        self.totalDeltaBytes = latestSnapshot.totalBytes - previousSnapshot.totalBytes
    }
}

public struct ScanProgress: Hashable, Sendable {
    public let message: String
    public let currentPath: String?

    public init(message: String, currentPath: String? = nil) {
        self.message = message
        self.currentPath = currentPath
    }
}

public struct IgnoredItem: Identifiable, Codable, Hashable, Sendable {
    public let key: String
    public let category: RecommendationCategory?
    public let path: String

    public var id: String { key }

    public init(key: String) {
        self.key = key

        let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            self.category = RecommendationCategory(rawValue: String(parts[0]))
            self.path = String(parts[1])
        } else {
            self.category = nil
            self.path = key
        }
    }
}
