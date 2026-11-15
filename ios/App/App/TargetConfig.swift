import Foundation

enum TargetConfig {
    static let targetBundleID = "com.coba.test"
    static let targetRelativePath = "Documents/contentcache/Compulsory/ios/gameassetbundles/"
    static let moveResource = "assets/move.txt"
    static let restoreResource = "assets/restore.txt"

    static func resource(for operation: String) throws -> String {
        switch operation {
        case "move":
            return moveResource
        case "restore":
            return restoreResource
        default:
            throw FileOperationError.invalidOperation
        }
    }

    static func pathComponents(for relativePath: String) throws -> [String] {
        guard relativePath == targetRelativePath else {
            throw FileOperationError.invalidTargetPath
        }

        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
            throw FileOperationError.invalidTargetPath
        }
        return components
    }
}

enum FileOperationError: LocalizedError {
    case invalidOperation
    case invalidTargetPath
    case sourceUnavailable(String)
    case destinationUnavailable(String)
    case destinationConflict
    case destinationChanged
    case invalidDestinationFile
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidOperation:
            return "Unsupported operation."
        case .invalidTargetPath:
            return "The destination path does not match the configured safe path."
        case .sourceUnavailable(let reason):
            return "Bundled source validation failed: \(reason)"
        case .destinationUnavailable(let reason):
            return "Destination access is unavailable: \(reason)"
        case .destinationConflict:
            return "A destination file already exists. Confirm overwrite before retrying."
        case .destinationChanged:
            return "The destination changed after inspection. Inspect it again before retrying."
        case .invalidDestinationFile:
            return "The destination is not a regular file."
        case .verificationFailed:
            return "The written file did not match the source resource."
        }
    }
}
