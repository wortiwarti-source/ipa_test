import Capacitor
import UIKit
import UniformTypeIdentifiers

@objc(FileAccessPlugin)
final class FileAccessPlugin: CAPPlugin, CAPBridgedPlugin, UIDocumentPickerDelegate {
    let identifier = "FileAccessPlugin"
    let jsName = "FileAccessPlugin"
    let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "chooseDirectory", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "inspect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "execute", returnType: CAPPluginReturnPromise)
    ]

    private let operations = OperationManager()
    private var directoryPickerCall: CAPPluginCall?

    @objc func chooseDirectory(_ call: CAPPluginCall) {
        guard directoryPickerCall == nil else {
            call.reject("A folder selection is already in progress.")
            return
        }
        guard let presenter = bridge?.viewController else {
            call.reject("The iOS view controller is unavailable.")
            return
        }

        directoryPickerCall = call
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    @objc func inspect(_ call: CAPPluginCall) {
        do {
            guard let operation = call.getString("operation") else {
                throw FileOperationError.invalidOperation
            }
            call.resolve(try operations.inspect(operation: operation))
        } catch {
            call.reject(error.localizedDescription)
        }
    }

    @objc func execute(_ call: CAPPluginCall) {
        do {
            guard let operation = call.getString("operation") else {
                throw FileOperationError.invalidOperation
            }
            let overwrite = call.getBool("overwrite") ?? false
            let expectedFingerprint = call.getString("expectedDestination")
            call.resolve(try operations.execute(
                operation: operation,
                overwrite: overwrite,
                expectedFingerprint: expectedFingerprint
            ))
        } catch {
            NSLog("MOVE & RESTORE: operation failed: %@", error.localizedDescription)
            call.reject(error.localizedDescription)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let call = directoryPickerCall else { return }
        directoryPickerCall = nil
        guard let url = urls.first else {
            call.reject("No folder was selected.")
            return
        }

        do {
            let displayName = try operations.chooseDirectory(url)
            call.resolve(["displayName": displayName])
        } catch {
            call.reject("Could not save folder permission: \(error.localizedDescription)")
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        directoryPickerCall?.reject("Folder selection cancelled.")
        directoryPickerCall = nil
    }
}
