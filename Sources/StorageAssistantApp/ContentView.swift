import Foundation
import SwiftUI
import StorageAssistantCore

struct ContentView: View {
    @StateObject private var viewModel = StorageAssistantViewModel()
    @State private var selectedRecommendation: Recommendation?
    @State private var showingHistory = false
    @State private var showingSettings = false
    @State private var showingIgnoredItems = false

    var body: some View {
        NavigationSplitView {
            Sidebar(viewModel: viewModel)
        } detail: {
            RecommendationList(
                viewModel: viewModel,
                selectedRecommendation: $selectedRecommendation
            )
        }
        .toolbar {
            ToolbarItemGroup {
                ToolbarStatusText(viewModel.statusMessage)

                Button {
                    showingHistory = true
                } label: {
                    Label("History", systemImage: "clock")
                }

                Button {
                    showingIgnoredItems = true
                } label: {
                    Label("Ignored", systemImage: "eye.slash")
                }

                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }

                if viewModel.isScanning {
                    Button {
                        viewModel.cancelScan()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                } else {
                    Button {
                        viewModel.scan()
                    } label: {
                        Label("Scan Now", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .sheet(item: $selectedRecommendation) { recommendation in
            RecommendationDetailView(
                recommendation: recommendation,
                reveal: { viewModel.reveal(recommendation) },
                ignore: { viewModel.ignore(recommendation) },
                moveToTrash: { viewModel.moveToTrash(recommendation) }
            )
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView(
                history: viewModel.history,
                restore: { viewModel.restoreFromTrash($0) },
                reveal: { viewModel.revealHistoryItem($0) }
            )
        }
        .sheet(isPresented: $showingIgnoredItems) {
            IgnoredItemsView(
                ignoredItems: viewModel.ignoredItems,
                unignore: { viewModel.unignore($0) }
            )
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: viewModel)
        }
        .task {
            viewModel.scan()
        }
    }
}

private struct ToolbarStatusText: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: 280, alignment: .trailing)
    }
}

private struct Sidebar: View {
    @ObservedObject var viewModel: StorageAssistantViewModel

    var body: some View {
        List(selection: $viewModel.selectedReviewArea) {
            Section("Review Areas") {
                ForEach(ReviewArea.allCases) { area in
                    CategoryRow(
                        title: area.title,
                        symbol: area.symbol,
                        count: viewModel.count(for: area),
                        bytes: viewModel.bytes(for: area)
                    )
                    .tag(area)
                }
            }
        }
        .navigationTitle("Storage Assistant")
        .frame(minWidth: 240)
    }
}

private struct CategoryRow: View {
    let title: String
    let symbol: String
    let count: Int
    let bytes: Int64

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)

                Text("\(count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(StorageFormatting.bytes(bytes))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct RecommendationList: View {
    @ObservedObject var viewModel: StorageAssistantViewModel
    @Binding var selectedRecommendation: Recommendation?

    var body: some View {
        VStack(spacing: 0) {
            SummaryHeader(
                count: viewModel.visibleRecommendations.count,
                bytes: viewModel.totalPotentialBytes,
                isScanning: viewModel.isScanning,
                progress: viewModel.scanProgress,
                growthSummary: viewModel.growthSummary,
                diagnostics: viewModel.diagnostics
            )

            Divider()

            if viewModel.visibleRecommendations.isEmpty {
                EmptyState(isScanning: viewModel.isScanning)
            } else {
                List {
                    ForEach(viewModel.visibleRecommendations) { recommendation in
                        RecommendationRow(
                            recommendation: recommendation,
                            details: { selectedRecommendation = recommendation },
                            reveal: { viewModel.reveal(recommendation) },
                            ignore: { viewModel.ignore(recommendation) },
                            moveToTrash: { viewModel.moveToTrash(recommendation) }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(viewModel.selectedReviewArea.title)
    }
}

private struct SummaryHeader: View {
    let count: Int
    let bytes: Int64
    let isScanning: Bool
    let progress: ScanProgress?
    let growthSummary: GrowthSummary?
    let diagnostics: [PermissionDiagnostic]

    var body: some View {
        HStack(spacing: 22) {
            MetricBlock(title: "Recommendations", value: "\(count)")
            MetricBlock(title: "Estimated Reviewable Space", value: StorageFormatting.bytes(bytes))
            if let growthSummary {
                MetricBlock(
                    title: "Since Last Scan",
                    value: signedBytes(growthSummary.totalDeltaBytes)
                )
            }
            if !diagnostics.isEmpty {
                MetricBlock(title: "Scan Notes", value: "\(diagnostics.count)")
            }

            Spacer()

            if isScanning {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(progress?.message ?? "Scanning")
                            .font(.caption.weight(.medium))

                        if let currentPath = progress?.currentPath {
                            Text(currentPath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 340, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private func signedBytes(_ bytes: Int64) -> String {
        if bytes == 0 {
            return "No change"
        }

        let sign = bytes > 0 ? "+" : "-"
        return sign + StorageFormatting.bytes(abs(bytes))
    }
}

private struct MetricBlock: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.title3.weight(.semibold))
        }
    }
}

private struct EmptyState: View {
    let isScanning: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: isScanning ? "magnifyingglass" : "checkmark.circle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text(isScanning ? "Scanning..." : "Nothing to review")
                .font(.title3.weight(.semibold))

            Text(isScanning ? "Large folders can take a moment." : "No recommendations match the current filter.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecommendationRow: View {
    let recommendation: Recommendation
    let details: () -> Void
    let reveal: () -> Void
    let ignore: () -> Void
    let moveToTrash: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(recommendation.displayName)
                            .font(.headline)
                            .lineLimit(1)

                        RiskBadge(risk: recommendation.risk)
                        ConfidenceBadge(confidence: recommendation.confidence)
                    }

                    Text(recommendation.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Text(StorageFormatting.bytes(recommendation.sizeBytes))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }

            Text(recommendation.reason)
                .font(.callout)

            Text(recommendation.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Label(recommendation.category.title, systemImage: categorySymbol(recommendation.category))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    details()
                } label: {
                    Label("Details", systemImage: "info.circle")
                }

                Button {
                    reveal()
                } label: {
                    Label("Reveal", systemImage: "magnifyingglass")
                }

                Button {
                    ignore()
                } label: {
                    Label("Ignore", systemImage: "eye.slash")
                }

                Button(role: .destructive) {
                    moveToTrash()
                } label: {
                    Label(recommendation.defaultAction.title, systemImage: actionSymbol(for: recommendation))
                }
                .disabled(!recommendation.canMoveToTrash)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 10)
    }

    private func categorySymbol(_ category: RecommendationCategory) -> String {
        switch category {
        case .downloads: "arrow.down.circle"
        case .trash: "trash"
        case .caches: "externaldrive.badge.timemachine"
        case .logs: "doc.text.magnifyingglass"
        case .unity: "cube"
        case .xcode: "hammer"
        case .docker: "shippingbox"
        case .python: "terminal"
        case .node: "network"
        case .homebrew: "cup.and.saucer"
        case .buildArtifacts: "wrench.and.screwdriver"
        case .leftovers: "puzzlepiece.extension"
        }
    }

    private func actionSymbol(for recommendation: Recommendation) -> String {
        switch recommendation.defaultAction {
        case .moveToTrash: "trash"
        case .revealOnly: "lock"
        case .commandRecommended: "terminal"
        }
    }
}

private struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        Text(risk.title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch risk {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }

    private var background: Color {
        foreground.opacity(0.12)
    }
}

private struct ConfidenceBadge: View {
    let confidence: ConfidenceLevel

    var body: some View {
        Text(confidence.title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(.secondary)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

private struct RecommendationDetailView: View {
    let recommendation: Recommendation
    let reveal: () -> Void
    let ignore: () -> Void
    let moveToTrash: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(recommendation.displayName)
                        .font(.title2.weight(.semibold))

                    Text(recommendation.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .buttonStyle(.bordered)

                Text(StorageFormatting.bytes(recommendation.sizeBytes))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                DetailRow(label: "Category", value: recommendation.category.title)
                DetailRow(label: "Risk", value: recommendation.risk.title)
                DetailRow(label: "Confidence", value: recommendation.confidence.title)
                DetailRow(label: "Suggested Action", value: recommendation.defaultAction.title)
                DetailRow(label: "Created", value: formattedDate(recommendation.createdDate))
                DetailRow(label: "Modified", value: formattedDate(recommendation.modifiedDate))
                DetailRow(label: "Last Accessed", value: formattedDate(recommendation.accessedDate))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Reason")
                    .font(.headline)
                Text(recommendation.reason)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Safety Note")
                    .font(.headline)
                Text(recommendation.detail)
                    .foregroundStyle(.secondary)
            }

            if let commandSuggestion = recommendation.commandSuggestion {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recommended Command")
                        .font(.headline)
                    Text(commandSuggestion.reason)
                        .foregroundStyle(.secondary)
                    Text(commandSuggestion.command)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            Spacer()

            HStack {
                Button {
                    reveal()
                } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                }

                Spacer()

                Button {
                    ignore()
                    dismiss()
                } label: {
                    Label("Ignore", systemImage: "eye.slash")
                }

                Button(role: .destructive) {
                    moveToTrash()
                    dismiss()
                } label: {
                    Label(recommendation.defaultAction.title, systemImage: actionSymbol(for: recommendation))
                }
                .disabled(!recommendation.canMoveToTrash)
            }
            .buttonStyle(.bordered)
        }
        .padding(22)
        .frame(minWidth: 640, minHeight: 500)
    }

    private func actionSymbol(for recommendation: Recommendation) -> String {
        switch recommendation.defaultAction {
        case .moveToTrash: "trash"
        case .revealOnly: "lock"
        case .commandRecommended: "terminal"
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}

private struct HistoryView: View {
    let history: [CleanupHistoryEntry]
    let restore: (CleanupHistoryEntry) -> Void
    let reveal: (CleanupHistoryEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Cleanup History")
                    .font(.title2.weight(.semibold))

                Spacer()

                Button("Done") {
                    dismiss()
                }
            }

            if history.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)

                    Text("No cleanup actions yet")
                        .font(.headline)

                    Text("Items moved to Trash will appear here with their original path.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(history) { entry in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(entry.category.title)
                                    .font(.headline)

                                if entry.restoredDate != nil {
                                    Text("Restored")
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .foregroundStyle(.green)
                                        .background(Color.green.opacity(0.12), in: Capsule())
                                }

                                Spacer()

                                Text(StorageFormatting.bytes(entry.sizeBytes))
                                    .font(.headline)
                                    .monospacedDigit()
                            }

                            Text(entry.originalPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            if let trashedPath = entry.trashedPath {
                                Text("Trash: \(trashedPath)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Text(formattedDate(entry.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            reveal(entry)
                        } label: {
                            Label("Reveal", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            restore(entry)
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!entry.canRestoreFromTrash)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(22)
        .frame(minWidth: 720, minHeight: 500)
    }
}

private struct IgnoredItemsView: View {
    let ignoredItems: [IgnoredItem]
    let unignore: (IgnoredItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Ignored Items")
                    .font(.title2.weight(.semibold))

                Spacer()

                Button("Done") {
                    dismiss()
                }
            }

            if ignoredItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)

                    Text("No ignored items")
                        .font(.headline)

                    Text("Recommendations you ignore will appear here so you can restore them later.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(ignoredItems) { item in
                    HStack(spacing: 12) {
                        Image(systemName: ignoredSymbol(for: item.category))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.category?.title ?? "Unknown")
                                .font(.headline)

                            Text(URL(fileURLWithPath: item.path).storageAssistantDisplayPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }

                        Spacer()

                        Button {
                            unignore(item)
                        } label: {
                            Label("Unignore", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(22)
        .frame(minWidth: 720, minHeight: 500)
    }

    private func ignoredSymbol(for category: RecommendationCategory?) -> String {
        switch category {
        case .downloads: "arrow.down.circle"
        case .trash: "trash"
        case .caches: "externaldrive.badge.timemachine"
        case .logs: "doc.text.magnifyingglass"
        case .unity: "cube"
        case .xcode: "hammer"
        case .docker: "shippingbox"
        case .python: "terminal"
        case .node: "network"
        case .homebrew: "cup.and.saucer"
        case .buildArtifacts: "wrench.and.screwdriver"
        case .leftovers: "puzzlepiece.extension"
        case nil: "questionmark.circle"
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var viewModel: StorageAssistantViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var thresholds: CleanupThresholds

    init(viewModel: StorageAssistantViewModel) {
        self.viewModel = viewModel
        _thresholds = State(initialValue: viewModel.settings.thresholds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Scan Settings")
                    .font(.title2.weight(.semibold))

                Spacer()

                Button("Done") {
                    dismiss()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Developer Project Roots")
                    .font(.headline)

                Text("Storage Assistant searches these folders for Unity projects, node_modules, and Python virtual environments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            List {
                ForEach(viewModel.settings.developerScanRootPaths, id: \.self) { path in
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)

                        Text(URL(fileURLWithPath: path).storageAssistantDisplayPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        Spacer()

                        Button {
                            viewModel.removeDeveloperScanRoot(path)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                }
            }
            .frame(minHeight: 180)

            HStack {
                Button {
                    viewModel.addDeveloperScanRoot()
                } label: {
                    Label("Add Folder", systemImage: "plus")
                }

                Button {
                    viewModel.resetDeveloperScanRoots()
                } label: {
                    Label("Reset Defaults", systemImage: "arrow.counterclockwise")
                }

                Spacer()

                Stepper(
                    value: Binding(
                        get: { viewModel.settings.projectSearchDepth },
                        set: { viewModel.updateProjectSearchDepth($0) }
                    ),
                    in: 1...8
                ) {
                    Text("Project search depth: \(viewModel.settings.projectSearchDepth)")
                }
                .frame(width: 240)
            }
            .buttonStyle(.bordered)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Thresholds")
                    .font(.headline)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    ThresholdStepper(
                        title: "Downloads",
                        value: Binding(
                            get: { thresholds.minimumDownloadBytes },
                            set: { thresholds.minimumDownloadBytes = $0 }
                        )
                    )
                    ThresholdStepper(
                        title: "Caches",
                        value: Binding(
                            get: { thresholds.minimumCacheBytes },
                            set: { thresholds.minimumCacheBytes = $0 }
                        )
                    )
                    ThresholdStepper(
                        title: "Developer artifacts",
                        value: Binding(
                            get: { thresholds.minimumDeveloperArtifactBytes },
                            set: { thresholds.minimumDeveloperArtifactBytes = $0 }
                        )
                    )
                    DaysStepper(
                        title: "Old downloads",
                        value: Binding(
                            get: { thresholds.oldDownloadDays },
                            set: { thresholds.oldDownloadDays = $0 }
                        )
                    )
                    DaysStepper(
                        title: "Old caches",
                        value: Binding(
                            get: { thresholds.oldCacheDays },
                            set: { thresholds.oldCacheDays = $0 }
                        )
                    )
                    DaysStepper(
                        title: "Leftovers stale after",
                        value: Binding(
                            get: { thresholds.leftoverStaleDays },
                            set: { thresholds.leftoverStaleDays = $0 }
                        )
                    )
                }

                HStack {
                    Button {
                        thresholds = .default
                        viewModel.updateThresholds(thresholds)
                    } label: {
                        Label("Reset Thresholds", systemImage: "arrow.counterclockwise")
                    }

                    Spacer()

                    Button {
                        viewModel.updateThresholds(thresholds)
                    } label: {
                        Label("Save Thresholds", systemImage: "checkmark")
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(22)
        .frame(minWidth: 760, minHeight: 620)
    }
}

private struct ThresholdStepper: View {
    let title: String
    @Binding var value: Int64

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Stepper(
                value: $value,
                in: 0...(100 * 1_024 * 1_024 * 1_024),
                step: 50 * 1_024 * 1_024
            ) {
                Text(StorageFormatting.bytes(value))
                    .monospacedDigit()
            }
            .frame(width: 180, alignment: .leading)
        }
    }
}

private struct DaysStepper: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Stepper(
                value: $value,
                in: 0...3650,
                step: 7
            ) {
                Text("\(value) days")
                    .monospacedDigit()
            }
            .frame(width: 180, alignment: .leading)
        }
    }
}

private func formattedDate(_ date: Date?) -> String {
    guard let date else {
        return "Unknown"
    }

    return DateFormatter.localizedString(
        from: date,
        dateStyle: .medium,
        timeStyle: .short
    )
}
