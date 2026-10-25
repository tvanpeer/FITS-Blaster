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

    /// The folder and options chosen in the open panel.
    struct FolderChoice {
        let url: URL
        let includeSubfolders: Bool
        let includeRejected: Bool
    }

    /// Asks for a folder, with the two options as checkboxes in the panel; they start
    /// from the defaults in Settings. Nil when the user cancels.
    static func chooseFolder(includeSubfolders: Bool, includeRejected: Bool) async -> FolderChoice? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing FITS files"
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

        guard await panel.begin() == .OK, let url = panel.url else { return nil }
        return FolderChoice(url: url,
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
        if store.isAlreadyLoaded(choice.url),
           await !confirmOpenAgain(folderName: choice.url.lastPathComponent) { return }
        await store.openFolder(at: choice.url, includeSubfolders: choice.includeSubfolders,
                               includeRejected: choice.includeRejected, settings: settings)
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
