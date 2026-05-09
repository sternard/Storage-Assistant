import Foundation

public final class UserStateStore {
    private struct State: Codable {
        var ignoredKeys: [String]
        var cleanupHistory: [CleanupHistoryEntry]
        var appSettings: AppSettings?
        var scanSnapshots: [ScanSnapshot]?

        static let empty = State(ignoredKeys: [], cleanupHistory: [], appSettings: nil, scanSnapshots: nil)
    }

    private let fileManager: FileManager
    private let stateURL: URL

    public init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) {
        self.fileManager = fileManager

        let supportDirectory = baseDirectory ?? fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Storage Assistant", isDirectory: true)

        self.stateURL = supportDirectory.appendingPathComponent("state.json")
    }

    public func loadIgnoredKeys() -> Set<String> {
        Set(loadState().ignoredKeys)
    }

    public func loadIgnoredItems() -> [IgnoredItem] {
        loadState().ignoredKeys
            .map(IgnoredItem.init(key:))
            .sorted { lhs, rhs in
                if lhs.category?.title != rhs.category?.title {
                    return (lhs.category?.title ?? "Other") < (rhs.category?.title ?? "Other")
                }
                return lhs.path < rhs.path
            }
    }

    public func loadHistory() -> [CleanupHistoryEntry] {
        loadState().cleanupHistory.sorted { $0.date > $1.date }
    }

    public func loadSnapshots() -> [ScanSnapshot] {
        (loadState().scanSnapshots ?? []).sorted { $0.date > $1.date }
    }

    public func loadGrowthSummary() -> GrowthSummary? {
        GrowthSummary(snapshots: loadSnapshots())
    }

    public func loadSettings(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AppSettings {
        loadState().appSettings?.sanitized(fileManager: fileManager) ??
            .defaults(homeDirectory: homeDirectory, fileManager: fileManager)
    }

    public func ignore(_ recommendation: Recommendation) throws {
        var state = loadState()
        if !state.ignoredKeys.contains(recommendation.ignoreKey) {
            state.ignoredKeys.append(recommendation.ignoreKey)
        }
        try save(state)
    }

    public func unignore(_ ignoredItem: IgnoredItem) throws {
        try unignoreKey(ignoredItem.key)
    }

    public func unignoreKey(_ key: String) throws {
        var state = loadState()
        state.ignoredKeys.removeAll { $0 == key }
        try save(state)
    }

    public func recordCleanup(_ entry: CleanupHistoryEntry) throws {
        var state = loadState()
        state.cleanupHistory.append(entry)
        try save(state)
    }

    public func markCleanupRestored(id: UUID, restoredDate: Date = Date()) throws {
        var state = loadState()
        guard let index = state.cleanupHistory.firstIndex(where: { $0.id == id }) else {
            return
        }

        state.cleanupHistory[index].restoredDate = restoredDate
        try save(state)
    }

    public func saveSettings(_ settings: AppSettings) throws {
        var state = loadState()
        state.appSettings = settings.sanitized(fileManager: fileManager)
        try save(state)
    }

    public func recordScanSnapshot(_ result: ScanResult, maxSnapshots: Int = 12) throws {
        var state = loadState()
        var snapshots = state.scanSnapshots ?? []
        snapshots.append(ScanSnapshot(result: result))
        state.scanSnapshots = Array(snapshots.sorted { $0.date > $1.date }.prefix(maxSnapshots))
        try save(state)
    }

    private func loadState() -> State {
        guard
            let data = try? Data(contentsOf: stateURL),
            let state = try? JSONDecoder().decode(State.self, from: data)
        else {
            return .empty
        }
        return state
    }

    private func save(_ state: State) throws {
        try fileManager.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: [.atomic])
    }
}
