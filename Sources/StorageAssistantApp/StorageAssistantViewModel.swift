import AppKit
import Foundation
import StorageAssistantCore

enum ReviewArea: String, CaseIterable, Identifiable, Hashable {
    case all
    case quickWins
    case userFiles
    case cachesAndLogs
    case developerStorage
    case appLeftovers
    case highRisk
    case systemData

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Recommendations"
        case .quickWins: "Quick Wins"
        case .userFiles: "User Files"
        case .cachesAndLogs: "Caches & Logs"
        case .developerStorage: "Developer Storage"
        case .appLeftovers: "App Leftovers & Services"
        case .highRisk: "High Risk Review"
        case .systemData: "System Data Lens"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .quickWins: "checkmark.circle"
        case .userFiles: "folder"
        case .cachesAndLogs: "externaldrive.badge.timemachine"
        case .developerStorage: "hammer"
        case .appLeftovers: "puzzlepiece.extension"
        case .highRisk: "exclamationmark.triangle"
        case .systemData: "internaldrive"
        }
    }

    func contains(_ recommendation: Recommendation) -> Bool {
        switch self {
        case .all:
            true
        case .quickWins:
            recommendation.risk == .low && recommendation.canMoveToTrash
        case .userFiles:
            [.downloads, .trash].contains(recommendation.category)
        case .cachesAndLogs:
            [.caches, .logs].contains(recommendation.category)
        case .developerStorage:
            [
                .unity,
                .xcode,
                .docker,
                .python,
                .node,
                .homebrew,
                .buildArtifacts
            ].contains(recommendation.category)
        case .appLeftovers:
            recommendation.category == .leftovers || recommendation.defaultAction == .commandRecommended
        case .highRisk:
            recommendation.risk == .high
        case .systemData:
            false
        }
    }
}

private final class ScanCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock {
            cancelled = true
        }
    }

    var isCancelled: Bool {
        lock.withLock {
            cancelled
        }
    }
}

@MainActor
final class StorageAssistantViewModel: ObservableObject {
    @Published var recommendations: [Recommendation] = []
    @Published var selectedReviewArea: ReviewArea = .all
    @Published var isScanning = false
    @Published var lastScanDate: Date?
    @Published var statusMessage = "Ready"
    @Published var scanProgress: ScanProgress?
    @Published var settings: AppSettings
    @Published var history: [CleanupHistoryEntry]
    @Published var ignoredItems: [IgnoredItem]
    @Published var diagnostics: [PermissionDiagnostic] = []
    @Published var growthSummary: GrowthSummary?
    @Published var systemDataBreakdown: SystemDataBreakdown?

    private let stateStore: UserStateStore
    private var ignoredKeys: Set<String>
    private var scanTask: Task<Void, Never>?
    private var scanCancellationToken: ScanCancellationToken?

    init() {
        let stateStore = UserStateStore()
        self.stateStore = stateStore
        self.ignoredKeys = stateStore.loadIgnoredKeys()
        self.settings = stateStore.loadSettings()
        self.history = stateStore.loadHistory()
        self.ignoredItems = stateStore.loadIgnoredItems()
        self.growthSummary = stateStore.loadGrowthSummary()
    }

    var visibleRecommendations: [Recommendation] {
        let visible = recommendations.filter { !ignoredKeys.contains($0.ignoreKey) }
        return visible.filter { selectedReviewArea.contains($0) }
    }

    var totalPotentialBytes: Int64 {
        visibleRecommendations.reduce(0) { $0 + $1.sizeBytes }
    }

    var allVisibleRecommendations: [Recommendation] {
        recommendations.filter { !ignoredKeys.contains($0.ignoreKey) }
    }

    func count(for area: ReviewArea) -> Int {
        if area == .systemData {
            return systemDataBreakdown?.entries.count ?? 0
        }

        return allVisibleRecommendations.filter { area.contains($0) }.count
    }

    func bytes(for area: ReviewArea) -> Int64 {
        if area == .systemData {
            return systemDataBreakdown?.totalKnownBytes ?? 0
        }

        let items = allVisibleRecommendations.filter { area.contains($0) }
        return items.reduce(0) { $0 + $1.sizeBytes }
    }

    func scan() {
        guard !isScanning else { return }
        let config = scannerConfig()
        let cancellationToken = ScanCancellationToken()
        scanCancellationToken = cancellationToken

        isScanning = true
        scanProgress = ScanProgress(message: "Preparing scan")
        statusMessage = "Scanning selected user and developer locations..."

        scanTask = Task { [weak self] in
            guard let self else { return }

            let progressHandler: @Sendable (ScanProgress) -> Void = { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.scanProgress = progress
                    self?.statusMessage = progress.message
                }
            }

            let result = await Task.detached(priority: .userInitiated) {
                StorageScanner(
                    config: config,
                    progressHandler: progressHandler,
                    shouldCancel: {
                        cancellationToken.isCancelled || Task.isCancelled
                    }
                ).scan()
            }.value

            guard !Task.isCancelled, !cancellationToken.isCancelled else {
                isScanning = false
                scanProgress = nil
                statusMessage = "Scan cancelled."
                return
            }

            recommendations = result.recommendations
            diagnostics = result.diagnostics
            systemDataBreakdown = result.systemDataBreakdown?.filtered(ignoredKeys: ignoredKeys)
            lastScanDate = result.scanDate
            var snapshotSaveError: String?
            do {
                try stateStore.recordScanSnapshot(result)
                growthSummary = stateStore.loadGrowthSummary()
            } catch {
                snapshotSaveError = error.localizedDescription
            }
            isScanning = false
            scanProgress = nil
            scanCancellationToken = nil
            if let snapshotSaveError {
                statusMessage = "Scan finished, but snapshot was not saved: \(snapshotSaveError)"
            } else {
                let diagnosticText = diagnostics.isEmpty ? "" : " \(diagnostics.count) scan notes."
                statusMessage = "Found \(allVisibleRecommendations.count) recommendations.\(diagnosticText)"
            }
        }
    }

    func cancelScan() {
        scanCancellationToken?.cancel()
        scanTask?.cancel()
        statusMessage = "Cancelling scan..."
    }

    func reveal(_ recommendation: Recommendation) {
        let url = URL(fileURLWithPath: recommendation.path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealSystemDataPath(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func ignore(_ recommendation: Recommendation) {
        do {
            try stateStore.ignore(recommendation)
            ignoredKeys.insert(recommendation.ignoreKey)
            ignoredItems = stateStore.loadIgnoredItems()
            statusMessage = "Ignored \(recommendation.displayName)."
        } catch {
            statusMessage = "Could not save ignore rule: \(error.localizedDescription)"
        }
    }

    func unignore(_ ignoredItem: IgnoredItem) {
        do {
            try stateStore.unignore(ignoredItem)
            ignoredKeys.remove(ignoredItem.key)
            ignoredItems = stateStore.loadIgnoredItems()
            statusMessage = "Restored ignored item."
        } catch {
            statusMessage = "Could not update ignore list: \(error.localizedDescription)"
        }
    }

    func moveToTrash(_ recommendation: Recommendation) {
        guard recommendation.canMoveToTrash else {
            statusMessage = "\(recommendation.displayName) is review-only."
            return
        }

        do {
            let originalURL = URL(fileURLWithPath: recommendation.path)
            var trashedURL: NSURL?
            try FileManager.default.trashItem(
                at: originalURL,
                resultingItemURL: &trashedURL
            )

            let entry = CleanupHistoryEntry(
                originalPath: recommendation.path,
                trashedPath: (trashedURL as URL?)?.path,
                sizeBytes: recommendation.sizeBytes,
                category: recommendation.category
            )
            try stateStore.recordCleanup(entry)
            history = stateStore.loadHistory()
            recommendations.removeAll { $0.id == recommendation.id }
            statusMessage = "Moved \(recommendation.displayName) to Trash."
        } catch {
            statusMessage = "Could not move item to Trash: \(error.localizedDescription)"
        }
    }

    func restoreFromTrash(_ entry: CleanupHistoryEntry) {
        guard let trashedPath = entry.trashedPath else {
            statusMessage = "This cleanup action has no Trash location."
            return
        }

        guard FileManager.default.fileExists(atPath: trashedPath) else {
            statusMessage = "The item is no longer in the Trash."
            return
        }

        guard !FileManager.default.fileExists(atPath: entry.originalPath) else {
            statusMessage = "Cannot restore because the original path already exists."
            return
        }

        do {
            let originalURL = URL(fileURLWithPath: entry.originalPath)
            try FileManager.default.createDirectory(
                at: originalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(
                at: URL(fileURLWithPath: trashedPath),
                to: originalURL
            )
            try stateStore.markCleanupRestored(id: entry.id)
            history = stateStore.loadHistory()
            statusMessage = "Restored item from Trash."
        } catch {
            statusMessage = "Could not restore item: \(error.localizedDescription)"
        }
    }

    func revealHistoryItem(_ entry: CleanupHistoryEntry) {
        if FileManager.default.fileExists(atPath: entry.originalPath) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.originalPath)])
        } else if let trashedPath = entry.trashedPath, FileManager.default.fileExists(atPath: trashedPath) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: trashedPath)])
        } else {
            statusMessage = "The item is not available at its original or Trash path."
        }
    }

    func addDeveloperScanRoot() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose a folder where Storage Assistant should look for developer projects."

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        var paths = settings.developerScanRootPaths
        let path = url.standardizedFileURL.path
        if !paths.contains(path) {
            paths.append(path)
        }

        updateSettings(
            AppSettings(
                developerScanRootPaths: paths,
                projectSearchDepth: settings.projectSearchDepth,
                thresholds: settings.thresholds
            )
        )
    }

    func removeDeveloperScanRoot(_ path: String) {
        updateSettings(
            AppSettings(
                developerScanRootPaths: settings.developerScanRootPaths.filter { $0 != path },
                projectSearchDepth: settings.projectSearchDepth,
                thresholds: settings.thresholds
            )
        )
    }

    func resetDeveloperScanRoots() {
        updateSettings(.defaults())
    }

    func updateProjectSearchDepth(_ depth: Int) {
        updateSettings(
            AppSettings(
                developerScanRootPaths: settings.developerScanRootPaths,
                projectSearchDepth: depth,
                thresholds: settings.thresholds
            )
        )
    }

    func updateThresholds(_ thresholds: CleanupThresholds) {
        updateSettings(
            AppSettings(
                developerScanRootPaths: settings.developerScanRootPaths,
                projectSearchDepth: settings.projectSearchDepth,
                thresholds: thresholds
            )
        )
    }

    private func updateSettings(_ newSettings: AppSettings) {
        let sanitized = newSettings.sanitized()
        settings = sanitized

        do {
            try stateStore.saveSettings(sanitized)
            statusMessage = "Scan settings saved."
        } catch {
            statusMessage = "Could not save scan settings: \(error.localizedDescription)"
        }
    }

    private func scannerConfig() -> ScannerConfig {
        let thresholds = settings.thresholds.sanitized
        var config = ScannerConfig(
            minimumDownloadBytes: thresholds.minimumDownloadBytes,
            largeDownloadBytes: thresholds.largeDownloadBytes,
            minimumCacheBytes: thresholds.minimumCacheBytes,
            minimumLogBytes: thresholds.minimumLogBytes,
            minimumDeveloperArtifactBytes: thresholds.minimumDeveloperArtifactBytes,
            oldDownloadDays: thresholds.oldDownloadDays,
            oldCacheDays: thresholds.oldCacheDays,
            oldLogDays: thresholds.oldLogDays,
            staleProjectDays: 90,
            projectSearchDepth: settings.projectSearchDepth,
            minimumLeftoverBytes: thresholds.minimumLeftoverBytes,
            leftoverStaleDays: thresholds.leftoverStaleDays
        )
        config.projectSearchDepth = settings.projectSearchDepth
        config.developerSearchRoots = settings.developerScanRootURLs
        return config
    }
}
