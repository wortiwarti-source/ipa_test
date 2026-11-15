import Foundation

struct BundledResource {
    let path: String
    let data: Data
    let modifiedAt: Date?

    var metadata: [String: Any] {
        [
            "resource": path,
            "sourceAvailable": true,
            "sourceSize": data.count,
            "sourceModifiedAt": modifiedAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull()
        ]
    }
}

final class ResourceManager {
    func load(_ resourcePath: String) throws -> BundledResource {
        let components = resourcePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard resourcePath == TargetConfig.moveResource || resourcePath == TargetConfig.restoreResource,
              components.count == 2,
              components[0] == "assets",
              components[1].hasSuffix(".txt") else {
            throw FileOperationError.sourceUnavailable("The resource path is not allowed.")
        }

        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("public", isDirectory: true),
            Bundle.main.bundleURL
        ]
        guard let url = candidates
            .map({ components.reduce($0) { $0.appendingPathComponent($1) } })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw FileOperationError.sourceUnavailable("The bundled file \(resourcePath) was not found.")
        }

        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw FileOperationError.sourceUnavailable("The resource is not a regular file.")
        }

        do {
            return BundledResource(
                path: resourcePath,
                data: try Data(contentsOf: url, options: [.mappedIfSafe]),
                modifiedAt: values.contentModificationDate
            )
        } catch {
            throw FileOperationError.sourceUnavailable(error.localizedDescription)
        }
    }
}
