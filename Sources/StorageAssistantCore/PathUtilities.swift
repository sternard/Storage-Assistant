import Foundation

struct FileMetadata {
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let fileSize: Int64
    let allocatedSize: Int64
    let createdDate: Date?
    let modifiedDate: Date?
    let accessedDate: Date?
}

extension URL {
    public var storageAssistantDisplayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = self.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

extension FileManager {
    func storageAssistantFileExists(at url: URL) -> Bool {
        fileExists(atPath: url.path)
    }

    func storageAssistantMetadata(for url: URL) -> FileMetadata? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .contentAccessDateKey
        ]

        guard let values = try? url.resourceValues(forKeys: keys) else {
            return nil
        }

        let attributeSize = (try? attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let fileSize = max(Int64(values.fileSize ?? 0), attributeSize)
        let allocatedSize = Int64(
            [
                values.totalFileAllocatedSize,
                values.fileAllocatedSize,
                values.fileSize,
                Int(fileSize)
            ]
            .compactMap { $0 }
            .first { $0 > 0 } ?? 0
        )

        return FileMetadata(
            isDirectory: values.isDirectory == true,
            isSymbolicLink: values.isSymbolicLink == true,
            fileSize: fileSize,
            allocatedSize: allocatedSize,
            createdDate: values.creationDate,
            modifiedDate: values.contentModificationDate,
            accessedDate: values.contentAccessDate
        )
    }
}
