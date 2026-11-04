//
//  SidebarFrameMenu.swift
//  FITS Blaster
//
//  The context menu of a frame in the thumbnail bar: Show in Finder, Copy File Path,
//  Flag/Deflag, Reject / Undo Reject and Remove from List. It acts on the orange selection
//  when the right-clicked frame is part of it, otherwise on that frame alone (as Finder).
//  Its own view, so the state it reads redraws only the menu, not the cells (P1).
//

import AppKit
import SwiftUI

struct SidebarFrameMenu: View {
    let entry: ImageEntry
    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let targets = store.frameMenuTargets(for: entry)
        let model = store.frameMenuModel(for: targets, useToggleReject: settings.useToggleReject)

        Button("Show in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.url))
        }
        Button(model.copyPathTitle, systemImage: "doc.on.doc") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(ImageStore.filePathsText(targets.map(\.url)), forType: .string)
        }

        Divider()

        Button(model.flagTitle, systemImage: model.deflags ? "flag.slash" : "flag") {
            act { store.frameMenuToggleFlag(targets) }
        }
        .menuKey(settings.flagKey)

        ForEach(model.rejectItems, id: \.self) { item in
            switch item {
            case .reject:
                Button(model.title(.reject), systemImage: "xmark.circle") {
                    act { store.frameMenuReject(targets) }
                }
                .disabled(!model.isEnabled(.reject))
                .menuKey(settings.rejectKey)
            case .undoReject:
                Button(model.title(.undoReject), systemImage: "arrow.uturn.backward") {
                    act { store.frameMenuUndoReject(targets) }
                }
                .disabled(!model.isEnabled(.undoReject))
                // With toggle reject the reject key undoes too; the undo key is unused.
                .menuKey(settings.useToggleReject ? settings.rejectKey : settings.undoKey)
            }
        }

        Divider()

        // No key shown: the remove key removes the flagged frames (or the cursor frame),
        // not these targets.
        Button(model.removeTitle, systemImage: "minus.circle") {
            store.frameMenuRemove(targets)
        }
    }

    /// Runs a flag, reject or undo and moves the cursor on when its frame left the view
    /// (e.g. deflagged in the Flagged view), as the keys do.
    private func act(_ action: () -> Void) {
        let before = store.sidebarNavigationEntries(isSimpleMode: settings.isSimpleMode)
        action()
        store.advanceCursorIfNeeded(from: before)
    }
}

private extension View {
    /// Shows the key setting next to the menu item; nothing when it has no key equivalent.
    @ViewBuilder
    func menuKey(_ key: String) -> some View {
        if let equivalent = KeyEquivalent.fromSetting(key) {
            keyboardShortcut(equivalent, modifiers: [])
        } else {
            self
        }
    }
}
