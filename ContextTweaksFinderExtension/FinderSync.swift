import Cocoa
import FinderSync
import OSLog

class FinderSync: FIFinderSync {
    private let logger = Logger(
        subsystem: "com.timsc.ContextTweaks.FinderExtension",
        category: "FinderActions"
    )
    private let controller = FIFinderSyncController.default()
    private let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
    private var pendingDirectoryURL: URL?
    private var pendingCopyURLs: [URL] = []
    private let newFileMenuTitle = NSLocalizedString(
        "new_file",
        tableName: nil,
        bundle: .main,
        value: "New File",
        comment: "Finder context-menu command that creates an empty file"
    )
    private let copyPathMenuTitle = NSLocalizedString(
        "copy_path_to_clipboard",
        tableName: nil,
        bundle: .main,
        value: "Copy Path to Clipboard",
        comment: "Finder context-menu command that copies absolute paths"
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

        switch menuKind {
        case .contextualMenuForContainer:
            guard let directoryURL = controller.targetedURL(), directoryURL.isFileURL else {
                return menu
            }

            pendingDirectoryURL = directoryURL

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return menu
            }

            menu.addItem(withTitle: newFileMenuTitle, action: #selector(createNewFile(_:)), keyEquivalent: "")
            addCopyPathItem(to: menu, urls: [directoryURL])
        case .contextualMenuForItems:
            guard let selectedItemURLs = controller.selectedItemURLs()?.filter(\.isFileURL), !selectedItemURLs.isEmpty else {
                return menu
            }

            addCopyPathItem(to: menu, urls: selectedItemURLs)
        default:
            break
        }

        return menu
    }

    private func addCopyPathItem(to menu: NSMenu, urls: [URL]) {
        pendingCopyURLs = urls
        let item = menu.addItem(withTitle: copyPathMenuTitle, action: #selector(copyPathToClipboard(_:)), keyEquivalent: "")

        // Keep the exact menu targets on the item. Finder selection can change
        // while a contextual menu is open, so resolving them again on click can
        // copy a path that the user did not invoke the command for.
        item.representedObject = urls
    }

    @objc @IBAction func copyPathToClipboard(_ sender: AnyObject?) {
        let representedURLs = (sender as? NSMenuItem)?.representedObject as? [URL]
        let targetURLs = representedURLs.flatMap { $0.isEmpty ? nil : $0 } ?? pendingCopyURLs

        guard PathClipboard.copy(urls: targetURLs) else {
            logger.error("Could not copy Finder paths to the clipboard")
            NSSound.beep()
            return
        }

        logger.notice("Copied \(targetURLs.count, privacy: .public) Finder path(s) to the clipboard")
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

enum PathClipboard {
    static func copy(urls: [URL], to pasteboard: NSPasteboard = .general) -> Bool {
        let paths = urls.compactMap { $0.isFileURL ? $0.path : nil }
        guard !paths.isEmpty else {
            return false
        }

        pasteboard.clearContents()
        return pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }
}
