import Cocoa
import Darwin
import OSLog

private let logger = Logger(
    subsystem: "com.timsc.NewFinderFile",
    category: "CreateFile"
)
private let requestScheme = "newfinderfile"
private let requestHost = "create"
private let newFileBaseName = NSLocalizedString(
    "new_file",
    tableName: nil,
    bundle: .main,
    value: "New File",
    comment: "Base name of the empty file created by the Finder command"
)

private func createUniquelyNamedFile(in directoryURL: URL) throws -> URL {
    for index in 1...10_000 {
        let name = index == 1 ? newFileBaseName : "\(newFileBaseName) \(index)"
        let candidate = directoryURL.appendingPathComponent(name, isDirectory: false)

        let descriptor = candidate.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o644))
        }

        if descriptor >= 0 {
            Darwin.close(descriptor)
            return candidate
        }

        let errorNumber = errno
        if errorNumber != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
        }
    }

    throw POSIXError(.EEXIST)
}

private func showAlert(message: String, style: NSAlert.Style) {
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.alertStyle = style
    alert.messageText = "NewFinderFile"
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

private func createFile(in directoryPath: String) {
    let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
        atPath: directoryURL.path,
        isDirectory: &isDirectory
    ), isDirectory.boolValue else {
        logger.error("Target is not a directory: \(directoryURL.path, privacy: .public)")
        showAlert(
            message: "Der Zielordner existiert nicht mehr:\n\(directoryURL.path)",
            style: .warning
        )
        return
    }

    logger.notice("Creating a file in \(directoryURL.path, privacy: .public)")

    do {
        let fileURL = try createUniquelyNamedFile(in: directoryURL)
        logger.notice("Created \(fileURL.path, privacy: .public)")
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    } catch {
        logger.error(
            "Creation failed in \(directoryURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        showAlert(
            message: "Die Datei konnte in diesem Ordner nicht erstellt werden:\n\(directoryURL.path)\n\n\(error.localizedDescription)",
            style: .warning
        )
    }
}

private func parseCreateRequest(_ requestURL: URL) -> (directoryURL: URL, requestID: String)? {
    guard requestURL.scheme?.lowercased() == requestScheme,
          requestURL.host?.lowercased() == requestHost,
          let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
          let directoryValue = components.queryItems?.first(where: { $0.name == "directory" })?.value,
          let directoryURL = URL(string: directoryValue),
          directoryURL.isFileURL else {
        return nil
    }

    let requestID = components.queryItems?.first(where: { $0.name == "request" })?.value
        ?? "unknown"
    return (directoryURL.standardizedFileURL, requestID)
}

private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var handledLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A direct launch has no work to do. Wait briefly so a cold
        // LaunchServices URL event can arrive, then exit silently.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.handledLaunch else {
                return
            }

            self.handledLaunch = true
            logger.notice("Exiting a direct launch with no create request")
            NSApplication.shared.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handledLaunch = true

        for requestURL in urls {
            guard let request = parseCreateRequest(requestURL) else {
                logger.error("Received an invalid URL create request")
                showAlert(
                    message: "Die Anfrage zum Erstellen einer Datei war ungültig.",
                    style: .warning
                )
                continue
            }

            logger.notice(
                "Received request \(request.requestID, privacy: .public) for \(request.directoryURL.path, privacy: .public)"
            )
            createFile(in: request.directoryURL.path)
        }

        application.terminate(nil)
    }
}

let arguments = CommandLine.arguments
let argumentDirectory: String?
if let markerIndex = arguments.firstIndex(of: "--create-file-in"),
   arguments.indices.contains(markerIndex + 1) {
    argumentDirectory = arguments[markerIndex + 1]
} else {
    argumentDirectory = nil
}

if let directoryPath = argumentDirectory, !directoryPath.isEmpty {
    logger.notice("Received command-line create request for \(directoryPath, privacy: .public)")
    createFile(in: directoryPath)
} else {
    let application = NSApplication.shared
    let applicationDelegate = ApplicationDelegate()
    application.delegate = applicationDelegate
    application.run()
}
