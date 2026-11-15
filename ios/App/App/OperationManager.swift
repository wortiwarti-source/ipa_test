import Foundation
import Darwin

private struct DestinationRoot {
    let url: URL
    let external: Bool
    let label: String
}

final class OperationManager {
    private let fileManager = FileManager.default
    private let resourceManager = ResourceManager()
    private let bookmarkKey = "moveRestore.selectedDirectoryBookmark"

    func chooseDirectory(_ url: URL) throws -> String {
        guard url.isFileURL, url.startAccessingSecurityScopedResource() else {
            throw FileOperationError.destinationUnavailable("The selected item is not a folder.")
        }
        defer { url.stopAccessingSecurityScopedResource() }
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw FileOperationError.destinationUnavailable("The selected item is not a folder.")
        }
        let data = try url.bookmarkData()
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        NSLog("MOVE & RESTORE: granted folder access saved.")
        return url.lastPathComponent
    }

    func inspect(operation: String) throws -> [String: Any] {
        let resource = try TargetConfig.resource(for: operation)
        let bundled = try resourceManager.load(resource)
        var result = bundled.metadata
        result["operation"] = operation
        result["fileName"] = URL(fileURLWithPath: resource).lastPathComponent

        do {
            let destination = try withDestination(operation: operation) { root, components, directory, file in
                try validateDirectoryPath(root: root.url, components: components, destination: directory)
                let parent = nearestExistingDirectory(from: directory, within: root.url)
                guard fileManager.isWritableFile(atPath: parent.path) else {
                    throw FileOperationError.destinationUnavailable("The nearest existing parent folder is read-only.")
                }

                let destinationExists = fileManager.fileExists(atPath: file.path)
                var fingerprint: String?
                var destinationSize = 0
                if destinationExists {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw FileOperationError.invalidDestinationFile
                    }
                    destinationSize = values.fileSize ?? 0
                    fingerprint = try fingerprintFor(file: file)
                }

                return [
                    "destinationAccessible": true,
                    "destinationExists": destinationExists,
                    "destinationSize": destinationSize,
                    "destinationFingerprint": fingerprint as Any? ?? NSNull(),
                    "destinationDirectoryExists": fileManager.fileExists(atPath: directory.path),
                    "accessLocation": root.label,
                    "destinationPath": file.path,
                    "externalFolderGranted": root.external
                ] as [String: Any]
            }
            result.merge(destination) { _, new in new }
        } catch {
            result["destinationAccessible"] = false
            result["destinationExists"] = false
            result["destinationSize"] = 0
            result["destinationFingerprint"] = NSNull()
            result["error"] = error.localizedDescription
        }

        NSLog("MOVE & RESTORE: inspected %@ resource (%ld bytes), destination access %@.",
              operation, bundled.data.count, (result["destinationAccessible"] as? Bool == true) ? "available" : "unavailable")
        return result
    }

    func execute(operation: String, overwrite: Bool, expectedFingerprint: String?) throws -> [String: Any] {
        let resource = try TargetConfig.resource(for: operation)
        let bundled = try resourceManager.load(resource)

        let result = try withDestination(operation: operation) { root, components, directory, file -> [String: Any] in
            try validateDirectoryPath(root: root.url, components: components, destination: directory)
            let parent = nearestExistingDirectory(from: directory, within: root.url)
            guard fileManager.isWritableFile(atPath: parent.path) else {
                throw FileOperationError.destinationUnavailable("The nearest existing parent folder is read-only.")
            }

            var exists = fileManager.fileExists(atPath: file.path)
            if exists {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw FileOperationError.invalidDestinationFile
                }
                guard overwrite else {
                    throw FileOperationError.destinationConflict
                }
                guard let expectedFingerprint,
                      try fingerprintFor(file: file) == expectedFingerprint else {
                    throw FileOperationError.destinationChanged
                }
            } else if overwrite || expectedFingerprint != nil {
                throw FileOperationError.destinationChanged
            }

            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try validateDirectoryPath(root: root.url, components: components, destination: directory)
                exists = fileManager.fileExists(atPath: file.path)
                if exists != (expectedFingerprint != nil) {
                    throw FileOperationError.destinationChanged
                }
                if exists {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          let expectedFingerprint,
                          try fingerprintFor(file: file) == expectedFingerprint else {
                        throw FileOperationError.destinationChanged
                    }
                }

                try write(bundled.data, to: file, overwrite: overwrite, expectedFingerprint: expectedFingerprint)
                let writtenData = try Data(contentsOf: file, options: [.mappedIfSafe])
                guard writtenData == bundled.data else {
                    throw FileOperationError.verificationFailed
                }
                let writtenSize = writtenData.count
                NSLog("MOVE & RESTORE: %@ completed and verified (%ld bytes).", operation, writtenSize)

                return [
                    "operation": operation,
                    "resource": resource,
                    "fileName": file.lastPathComponent,
                    "destinationPath": file.path,
                    "destinationSize": writtenSize,
                    "verified": true,
                    "accessLocation": root.label,
                    "externalFolderGranted": root.external
                ]
            } catch let error as FileOperationError {
                throw error
            } catch {
                throw FileOperationError.destinationUnavailable(error.localizedDescription)
            }
        }
        return result
    }

    private func withDestination<T>(
        operation: String,
        body: (DestinationRoot, [String], URL, URL) throws -> T
    ) throws -> T {
        _ = try TargetConfig.resource(for: operation)
        let components = try TargetConfig.pathComponents(for: TargetConfig.targetRelativePath)

        if let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) {
            var isStale = false
            let selectedURL: URL
            do {
                selectedURL = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
            } catch {
                throw FileOperationError.destinationUnavailable("The saved folder permission is no longer valid: \(error.localizedDescription)")
            }
            guard !isStale, selectedURL.startAccessingSecurityScopedResource() else {
                throw FileOperationError.destinationUnavailable("The selected folder permission expired. Select the folder again.")
            }
            defer { selectedURL.stopAccessingSecurityScopedResource() }
            let root = DestinationRoot(url: selectedURL, external: true, label: "iOS-granted folder")
            let directory = components.reduce(selectedURL) { $0.appendingPathComponent($1, isDirectory: true) }
            let file = directory.appendingPathComponent(URL(fileURLWithPath: try TargetConfig.resource(for: operation)).lastPathComponent)
            return try body(root, components, directory, file)
        }

        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw FileOperationError.destinationUnavailable("The app's Documents directory is unavailable.")
        }
        let containerURL = documentsURL.deletingLastPathComponent()
        let root = DestinationRoot(url: containerURL, external: false, label: "This app's Documents sandbox")
        let directory = components.reduce(containerURL) { $0.appendingPathComponent($1, isDirectory: true) }
        let file = directory.appendingPathComponent(URL(fileURLWithPath: try TargetConfig.resource(for: operation)).lastPathComponent)
        return try body(root, components, directory, file)
    }

    private func validateDirectoryPath(root: URL, components: [String], destination: URL) throws {
        var current = root
        for component in components {
            current.appendPathComponent(component, isDirectory: true)
            guard fileManager.fileExists(atPath: current.path) else { continue }
            let values = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw FileOperationError.destinationUnavailable("A destination path component is not a safe directory.")
            }
        }
        guard destination.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw FileOperationError.invalidTargetPath
        }
    }

    private func nearestExistingDirectory(from destination: URL, within root: URL) -> URL {
        var current = destination
        while !fileManager.fileExists(atPath: current.path), current.path != root.path {
            current.deleteLastPathComponent()
        }
        return current
    }

    private func fingerprintFor(file: URL) throws -> String {
        var fileInfo = stat()
        guard lstat(file.path, &fileInfo) == 0 else {
            throw FileOperationError.destinationUnavailable(String(cString: strerror(errno)))
        }
        guard fileInfo.st_mode & S_IFMT == S_IFREG else {
            throw FileOperationError.invalidDestinationFile
        }
        return fingerprint(for: fileInfo)
    }

    private func fingerprint(for fileInfo: stat) -> String {
        "\(fileInfo.st_dev)|\(fileInfo.st_ino)|\(fileInfo.st_size)|\(fileInfo.st_mtimespec.tv_sec)|\(fileInfo.st_mtimespec.tv_nsec)"
    }

    private func write(
        _ data: Data,
        to file: URL,
        overwrite: Bool,
        expectedFingerprint: String?
    ) throws {
        let alreadyExists = fileManager.fileExists(atPath: file.path)
        let descriptor: Int32

        if alreadyExists {
            guard overwrite else {
                throw FileOperationError.destinationConflict
            }
            guard let expectedFingerprint, try fingerprintFor(file: file) == expectedFingerprint else {
                throw FileOperationError.destinationChanged
            }
            descriptor = open(file.path, O_WRONLY | O_NOFOLLOW)
            guard descriptor >= 0 else {
                throw FileOperationError.destinationUnavailable(String(cString: strerror(errno)))
            }
            var openedInfo = stat()
            guard fstat(descriptor, &openedInfo) == 0,
                  fingerprint(for: openedInfo) == expectedFingerprint else {
                close(descriptor)
                throw FileOperationError.destinationChanged
            }
        } else {
            guard !overwrite, expectedFingerprint == nil else {
                throw FileOperationError.destinationChanged
            }
            descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
            guard descriptor >= 0 else {
                if errno == EEXIST {
                    throw FileOperationError.destinationConflict
                }
                throw FileOperationError.destinationUnavailable(String(cString: strerror(errno)))
            }
        }

        var completed = false
        defer {
            if !completed && !alreadyExists {
                var openInfo = stat()
                var pathInfo = stat()
                if fstat(descriptor, &openInfo) == 0,
                   lstat(file.path, &pathInfo) == 0,
                   openInfo.st_dev == pathInfo.st_dev,
                   openInfo.st_ino == pathInfo.st_ino {
                    _ = unlink(file.path)
                }
            }
            close(descriptor)
        }

        if alreadyExists && ftruncate(descriptor, 0) != 0 {
            throw FileOperationError.destinationUnavailable(String(cString: strerror(errno)))
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard let baseAddress = buffer.baseAddress else {
                    throw FileOperationError.destinationUnavailable("The source buffer is unavailable.")
                }
                let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                guard written > 0 else {
                    throw FileOperationError.destinationUnavailable(String(cString: strerror(errno)))
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else {
            throw FileOperationError.destinationUnavailable(String(cString: strerror(errno)))
        }
        guard try Data(contentsOf: file, options: [.mappedIfSafe]) == data else {
            throw FileOperationError.verificationFailed
        }
        completed = true
    }
}
