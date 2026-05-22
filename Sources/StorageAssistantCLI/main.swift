import Foundation
import StorageAssistantCore

let arguments = Set(CommandLine.arguments.dropFirst())
let jsonOutput = arguments.contains("--json")
let includeIgnored = arguments.contains("--include-ignored")
let showProgress = arguments.contains("--progress")

let store = UserStateStore()
let settings = store.loadSettings()
var config = ScannerConfig.default
config.projectSearchDepth = settings.projectSearchDepth
config.developerSearchRoots = settings.developerScanRootURLs

let scanner = StorageScanner(
    config: config,
    progressHandler: { progress in
        guard showProgress else { return }
        let path = progress.currentPath.map { " \($0)" } ?? ""
        FileHandle.standardError.write(Data("[scan] \(progress.message)\(path)\n".utf8))
    }
)
let result = scanner.scan()
let visibleResult = includeIgnored ? result : result.filtered(ignoredKeys: store.loadIgnoredKeys())

if jsonOutput {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(visibleResult)
    print(String(decoding: data, as: UTF8.self))
} else {
    print("Storage Assistant 0.2")
    print("Scan date: \(visibleResult.scanDate)")
    print("Recommendations: \(visibleResult.recommendations.count)")
    print("Estimated reviewable space: \(StorageFormatting.bytes(visibleResult.totalPotentialBytes))")
    if let breakdown = visibleResult.systemDataBreakdown {
        print("Visible System Data lens: \(StorageFormatting.bytes(breakdown.totalKnownBytes)) across \(breakdown.entries.count) locations")
    }
    print("")

    for recommendation in visibleResult.recommendations {
        print("[\(recommendation.risk.title)] \(recommendation.category.title): \(recommendation.displayName)")
        print("  Size: \(StorageFormatting.bytes(recommendation.sizeBytes))")
        print("  Path: \(recommendation.path)")
        print("  Reason: \(recommendation.reason)")
        print("  Action: \(recommendation.defaultAction.title)")
        print("")
    }

    if let breakdown = visibleResult.systemDataBreakdown, !breakdown.entries.isEmpty {
        print("System Data Lens")
        for entry in breakdown.entries.prefix(10) {
            print("[\(entry.category.title)] \(entry.title)")
            print("  Size: \(entry.sizeBytes.map(StorageFormatting.bytes) ?? "Unknown")")
            if let path = entry.path {
                print("  Path: \(path)")
            }
            print("  Detail: \(entry.detail)")
            if !entry.contributors.isEmpty {
                let contributors = entry.contributors
                    .prefix(5)
                    .map { contributor in
                        "\(contributor.displayName) \(StorageFormatting.bytes(contributor.sizeBytes))"
                    }
                    .joined(separator: ", ")
                print("  Largest visible contributors: \(contributors)")
            }
            print("")
        }
    }
}
