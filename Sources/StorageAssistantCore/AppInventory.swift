import AppKit
import Foundation

struct InstalledAppInventory {
    let bundleIdentifiers: Set<String>
    let normalizedNames: Set<String>
    let executableNames: Set<String>

    static func load(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        applicationRoots: [URL]? = nil,
        includeRunningApplications: Bool = true
    ) -> InstalledAppInventory {
        var bundleIdentifiers: Set<String> = []
        var normalizedNames: Set<String> = []
        var executableNames: Set<String> = []

        let roots = applicationRoots ?? [
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        ]

        for root in roots where fileManager.fileExists(atPath: root.path) {
            collectApps(
                under: root,
                maxDepth: 4,
                fileManager: fileManager,
                bundleIdentifiers: &bundleIdentifiers,
                normalizedNames: &normalizedNames,
                executableNames: &executableNames
            )
        }

        if includeRunningApplications {
            for app in NSWorkspace.shared.runningApplications {
                if let bundleIdentifier = app.bundleIdentifier {
                    bundleIdentifiers.insert(bundleIdentifier)
                }

                if let localizedName = app.localizedName {
                    normalizedNames.insert(normalizedAppToken(localizedName))
                }

                if let bundleURL = app.bundleURL {
                    addApp(
                        bundleURL,
                        bundleIdentifiers: &bundleIdentifiers,
                        normalizedNames: &normalizedNames,
                        executableNames: &executableNames
                    )
                }
            }
        }

        return InstalledAppInventory(
            bundleIdentifiers: bundleIdentifiers,
            normalizedNames: normalizedNames.filter { !$0.isEmpty },
            executableNames: executableNames.filter { !$0.isEmpty }
        )
    }

    func containsBundleIdentifierLike(_ identifier: String) -> Bool {
        let candidate = identifier.lowercased()
        guard !candidate.isEmpty else { return false }

        return bundleIdentifiers.contains { installed in
            let installed = installed.lowercased()
            return installed == candidate ||
                candidate.hasPrefix(installed + ".") ||
                installed.hasPrefix(candidate + ".")
        }
    }

    func containsNameLike(_ name: String) -> Bool {
        let normalized = normalizedAppToken(name)
        guard !normalized.isEmpty else { return false }
        return normalizedNames.contains(normalized) || executableNames.contains(normalized)
    }

    func containsRelatedNameLike(_ name: String) -> Bool {
        let normalized = normalizedAppToken(name)
        guard normalized.count >= 4 else { return false }

        if containsNameLike(name) {
            return true
        }

        return normalizedNames.contains { installed in
            installed.contains(normalized) || normalized.contains(installed)
        } || executableNames.contains { installed in
            installed.contains(normalized) || normalized.contains(installed)
        }
    }

    private static func collectApps(
        under root: URL,
        maxDepth: Int,
        fileManager: FileManager,
        bundleIdentifiers: inout Set<String>,
        normalizedNames: inout Set<String>,
        executableNames: inout Set<String>
    ) {
        var stack: [(url: URL, depth: Int)] = [(root, 0)]

        while let item = stack.popLast() {
            guard item.depth <= maxDepth else { continue }

            let children = (try? fileManager.contentsOfDirectory(
                at: item.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for child in children {
                guard
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                    values.isDirectory == true,
                    values.isSymbolicLink != true
                else {
                    continue
                }

                if child.pathExtension == "app" {
                    addApp(
                        child,
                        bundleIdentifiers: &bundleIdentifiers,
                        normalizedNames: &normalizedNames,
                        executableNames: &executableNames
                    )
                } else {
                    stack.append((child, item.depth + 1))
                }
            }
        }
    }

    private static func addApp(
        _ appURL: URL,
        bundleIdentifiers: inout Set<String>,
        normalizedNames: inout Set<String>,
        executableNames: inout Set<String>
    ) {
        guard let bundle = Bundle(url: appURL) else {
            normalizedNames.insert(normalizedAppToken(appURL.deletingPathExtension().lastPathComponent))
            return
        }

        if let bundleIdentifier = bundle.bundleIdentifier {
            bundleIdentifiers.insert(bundleIdentifier)
        }

        let info = bundle.infoDictionary ?? [:]
        let displayName = info["CFBundleDisplayName"] as? String
        let bundleName = info["CFBundleName"] as? String
        let executableName = info["CFBundleExecutable"] as? String

        [
            displayName,
            bundleName,
            appURL.deletingPathExtension().lastPathComponent
        ]
        .compactMap { $0 }
        .forEach { normalizedNames.insert(normalizedAppToken($0)) }

        if let executableName {
            executableNames.insert(normalizedAppToken(executableName))
        }
    }
}

struct RunningProcessInventory {
    struct Entry {
        let pid: Int
        let command: String
        let arguments: String

        var searchText: String {
            "\(command) \(arguments)".lowercased()
        }
    }

    let entries: [Entry]

    static func load() -> RunningProcessInventory {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return RunningProcessInventory(entries: [])
        }

        // Drain while the child is still running; waiting first can deadlock if ps
        // writes enough output to fill the pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return RunningProcessInventory(entries: [])
        }

        let output = String(decoding: data, as: UTF8.self)
        let entries = output
            .split(separator: "\n")
            .compactMap { line -> Entry? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let firstSpace = trimmed.firstIndex(where: { $0 == " " }) else {
                    return nil
                }

                let pidText = trimmed[..<firstSpace]
                guard let pid = Int(pidText) else { return nil }

                let remainder = trimmed[firstSpace...].trimmingCharacters(in: .whitespaces)
                let parts = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard let command = parts.first else { return nil }

                return Entry(
                    pid: pid,
                    command: String(command),
                    arguments: parts.count > 1 ? String(parts[1]) : ""
                )
            }

        return RunningProcessInventory(entries: entries)
    }

    func containsAny(_ terms: [String]) -> Bool {
        let normalizedTerms = terms
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count >= 4 }

        guard !normalizedTerms.isEmpty else {
            return false
        }

        return entries.contains { entry in
            normalizedTerms.contains { term in
                entry.searchText.contains(term)
            }
        }
    }
}

func normalizedAppToken(_ text: String) -> String {
    let trimmed = text
        .replacingOccurrences(of: ".app", with: "", options: [.caseInsensitive])
        .replacingOccurrences(of: ".plist", with: "", options: [.caseInsensitive])
        .replacingOccurrences(of: ".savedState", with: "", options: [.caseInsensitive])

    return trimmed
        .lowercased()
        .unicodeScalars
        .filter { CharacterSet.alphanumerics.contains($0) }
        .map(String.init)
        .joined()
}
