//
//  FileDialogs.swift
//  FITS Blaster
//
//  The open and save panels and the "already loaded" question, shown from the views;
//  the store only receives the chosen URL (master-plan step 4). The panels open with
//  `begin` instead of `runModal`, so they don't block the main thread while they are up.
//

import AppKit
import UniformTypeIdentifiers

@MainActor
enum FileDialogs {
    /// Asks where to save the frame list; nil when the user cancels.
    static func chooseExportDestination(format: ExportFormat) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Frame List"
        panel.nameFieldStringValue = "frames.\(format.fileExtension)"
        switch format {
        case .plainText: panel.allowedContentTypes = [.plainText]
        case .csv:       panel.allowedContentTypes = [.commaSeparatedText]
        case .tsv:       panel.allowedContentTypes = [.tabSeparatedText]
        }
        guard await panel.begin() == .OK else { return nil }
        return panel.url
    }

    // MARK: - Open Folder

    /// The folders and options chosen in the open panel.
    struct FolderChoice {
        /// One or more folders (⌘-click in the panel).
        let urls: [URL]
        let includeSubfolders: Bool
        let includeRejected: Bool
    }

    /// Asks for one or more folders, with the two options as checkboxes in the panel; they
    /// start from the defaults in Settings and apply to every folder chosen. Nil when the
    /// user cancels.
    static func chooseFolder(includeSubfolders: Bool, includeRejected: Bool) async -> FolderChoice? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Select one or more folders containing FITS files"
        panel.prompt = "Open"

        let subfolders = NSButton(checkboxWithTitle: "Include files from subfolders", target: nil, action: nil)
        subfolders.state = includeSubfolders ? .on : .off
        let rejected = NSButton(checkboxWithTitle: "Include REJECTED folder (mark images as rejected)",
                                target: nil, action: nil)
        rejected.state = includeRejected ? .on : .off
        let options = NSStackView(views: [subfolders, rejected])
        options.orientation = .vertical
        options.alignment = .leading
        options.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        options.setFrameSize(options.fittingSize)
        panel.accessoryView = options
        panel.isAccessoryViewDisclosed = true

        guard await panel.begin() == .OK, !panel.urls.isEmpty else { return nil }
        return FolderChoice(urls: panel.urls,
                            includeSubfolders: subfolders.state == .on,
                            includeRejected: rejected.state == .on)
    }

    /// Asks whether to open a folder that is already in the session; true to open it.
    static func confirmOpenAgain(folderName: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Folder Already Loaded"
        alert.informativeText = "\"\(folderName)\" is already in your session. Any duplicate files will be skipped automatically."
        alert.addButton(withTitle: "Open Anyway")
        alert.addButton(withTitle: "Cancel")
        if let window = NSApp.mainWindow {
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The whole Open Folder flow (toolbar button and ⌘O): choose, confirm a folder
    /// that is already loaded, then let the store scan and load it.
    static func openFolder(store: ImageStore, settings: AppSettings) async {
        guard let choice = await chooseFolder(includeSubfolders: settings.includeSubfolders,
                                              includeRejected: settings.includeRejectedFolder) else { return }
        var urls = choice.urls
        let loaded = urls.filter { store.isAlreadyLoaded($0) }
        if urls.count == 1, let folder = loaded.first {
            guard await confirmOpenAgain(folderName: folder.lastPathComponent) else { return }
        } else if !loaded.isEmpty,
                  await !confirmOpenAgain(folderNames: loaded.map(\.lastPathComponent)) {
            urls.removeAll { loaded.contains($0) }
        }
        guard !urls.isEmpty else { return }
        if urls.count == 1 {
            await store.openFolder(at: urls[0], includeSubfolders: choice.includeSubfolders,
                                   includeRejected: choice.includeRejected, settings: settings)
        } else {
            await store.openFolders(urls, includeSubfolders: choice.includeSubfolders,
                                    includeRejected: choice.includeRejected, settings: settings)
        }
    }

    /// Asks, once, about the chosen folders that are already in the session: true to open
    /// them again too ("Open Anyway"), false to skip them and open the others.
    static func confirmOpenAgain(folderNames: [String]) async -> Bool {
        let alert = NSAlert()
        alert.messageText = folderNames.count == 1 ? "A Folder Is Already Loaded" : "Some Folders Are Already Loaded"
        let list = folderNames.map { "\"\($0)\"" }.joined(separator: ", ")
        alert.informativeText = "\(list) \(folderNames.count == 1 ? "is" : "are") already in your session. Any duplicate files will be skipped automatically."
        alert.addButton(withTitle: "Open Anyway")
        alert.addButton(withTitle: folderNames.count == 1 ? "Skip It" : "Skip Those")
        if let window = NSApp.mainWindow {
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Folder access (sandbox)

    /// Asks the user to grant access to `folder`, so rejected frames can be moved into
    /// REJECTED inside it (frames dropped as single files in the App Store build).
    /// Returns the chosen folder, or nil when the user cancels.
    static func requestFolderAccess(_ folder: URL) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.message = "FITS Blaster needs access to \"\(folder.lastPathComponent)\" to move rejected frames into its REJECTED folder."
        panel.prompt = "Allow"
        guard await panel.begin() == .OK else { return nil }
        return panel.url
    }
}
