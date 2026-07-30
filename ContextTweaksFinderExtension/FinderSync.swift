import Cocoa
import FinderSync
import OSLog

class FinderSync: FIFinderSync {
    private let logger = Logger(
        subsystem: "com.timsc.ContextTweaks.FinderExtension",
        category: "CreateFile"
    )
    private let controller = FIFinderSyncController.default()
    private let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
    private var pendingDirectoryURL: URL?
    private let newFileMenuTitle = NSLocalizedString(
        "new_file",
        tableName: nil,
        bundle: .main,
        value: "New File",
        comment: "Finder context-menu command that creates an empty file"
    )

    override init() {
        super.init()

        refreshMonitoredDirectories()

        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(mountedVolumesDidChange(_:)),
            name: NSWorkspace.didMountNotification,
            object: nil
        )
        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(mountedVolumesDidChange(_:)),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )
    }

    deinit {
        workspaceNotificationCenter.removeObserver(self)
    }

    @objc private func mountedVolumesDidChange(_ notification: Notification) {
        refreshMonitoredDirectories()
    }

    private func refreshMonitoredDirectories() {
        var directoryURLs: Set<URL> = [
            URL(fileURLWithPath: "/", isDirectory: true).standardizedFileURL,
        ]

        // Finder Sync treats every mounted volume as a separate monitoring root.
        // Registering "/" alone does not cover external or network volumes.
        if let mountedVolumeURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        ) {
            directoryURLs.formUnion(mountedVolumeURLs.map(\.standardizedFileURL))
        }

        controller.directoryURLs = directoryURLs
        logger.notice("Monitoring \(directoryURLs.count, privacy: .public) Finder roots")
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")

        guard menuKind == .contextualMenuForContainer,
              let directoryURL = controller.targetedURL(),
              directoryURL.isFileURL else {
            return menu
        }

        pendingDirectoryURL = directoryURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return menu
        }

        menu.addItem(
            withTitle: newFileMenuTitle,
            action: #selector(createNewFile(_:)),
            keyEquivalent: ""
        )
        return menu
    }

    @objc @IBAction func createNewFile(_ sender: AnyObject?) {
        guard let directoryURL = controller.targetedURL() ?? pendingDirectoryURL else {
            logger.error("Finder invoked Context Tweaks without a target directory")
            NSSound.beep()
            return
        }

        guard directoryURL.isFileURL else {
            logger.error("Finder supplied a non-file target: \(directoryURL.absoluteString, privacy: .public)")
            NSSound.beep()
            return
        }

        // The extension itself is sandboxed. Its containing background app is
        // intentionally unsandboxed and performs the actual filesystem write.
        let hostApplicationURL = Bundle.main.bundleURL
            .deletingLastPathComponent() // PlugIns
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // Context Tweaks.app

        guard hostApplicationURL.pathExtension == "app" else {
            logger.error("Could not locate the containing Context Tweaks app")
            NSSound.beep()
            return
        }

        let requestID = UUID().uuidString
        var requestComponents = URLComponents()
        requestComponents.scheme = "contexttweaks"
        requestComponents.host = "create"
        requestComponents.queryItems = [
            URLQueryItem(name: "directory", value: directoryURL.absoluteString),
            URLQueryItem(name: "request", value: requestID),
        ]

        guard let requestURL = requestComponents.url else {
            logger.error("Could not encode create request \(requestID, privacy: .public)")
            NSSound.beep()
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false

        logger.notice(
            "Sending request \(requestID, privacy: .public) for \(directoryURL.path, privacy: .public)"
        )
        NSWorkspace.shared.open(
            [requestURL],
            withApplicationAt: hostApplicationURL,
            configuration: configuration
        ) { [logger] _, error in
            if let error {
                logger.error(
                    "Request \(requestID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                NSSound.beep()
            }
        }
    }
}
