//
//  KeyRecorderView.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 01/03/2026.
//

import SwiftUI
import AppKit

// MARK: - NSView backing

/// An invisible NSView that captures a single key press and reports it via callbacks.
/// Automatically becomes first responder when added to a window.
final class KeyRecorderNSView: NSView {
    var onKeyCapture: ((String) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // Check function-key area (arrow keys, etc.)
        if let specialKey = event.specialKey {
            switch specialKey {
            case .upArrow:    onKeyCapture?("↑")
            case .downArrow:  onKeyCapture?("↓")
            case .leftArrow:  onKeyCapture?("←")
            case .rightArrow: onKeyCapture?("→")
            case .home:       onKeyCapture?("⇱")
            case .end:        onKeyCapture?("⇲")
            default:          super.keyDown(with: event)
            }
            return
        }

        // Escape (key code 53) cancels recording
        if event.keyCode == 53 {
            onCancel?()
            return
        }

        // Return / Enter also cancels (key codes 36, 76)
        if event.keyCode == 36 || event.keyCode == 76 {
            onCancel?()
            return
        }

        // Space bar
        if event.keyCode == 49 {
            onKeyCapture?(" ")
            return
        }

        // Accept printable characters (letters, digits, punctuation, symbols)
        if let char = event.charactersIgnoringModifiers?.first,
           char.isLetter || char.isNumber || char.isPunctuation || char.isSymbol {
            onKeyCapture?(String(char).lowercased())
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - NSViewRepresentable

private struct KeyRecorderRepresentable: NSViewRepresentable {
    var onKeyCapture: (String) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> KeyRecorderNSView {
        let view = KeyRecorderNSView()
        view.onKeyCapture = onKeyCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: KeyRecorderNSView, context: Context) {
        nsView.onKeyCapture = onKeyCapture
        nsView.onCancel = onCancel
    }
}

// MARK: - SwiftUI button

/// A button that records a single key press and stores it as a binding.
///
/// When clicked the button enters recording mode showing "Press a key…".
/// Pressing any valid key captures it; pressing Escape cancels without changes.
///
/// Pass `conflictingKeys` to automatically clear any other binding that already
/// holds the newly assigned key, preventing duplicate shortcuts.
struct KeyRecorderButton: View {
    @Binding var keyString: String
    var conflictingKeys: [Binding<String>] = []

    @State private var isRecording = false

    var body: some View {
        if isRecording {
            HStack {
                Text("Press a key…")
                    .foregroundStyle(.secondary)

                Button("Cancel", systemImage: "xmark.circle.fill") {
                    isRecording = false
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)

                // Hidden recorder view — auto-becomes first responder
                KeyRecorderRepresentable(
                    onKeyCapture: { key in
                        if conflictingKeys.contains(where: { $0.wrappedValue == key }) {
                            NSSound.beep()
                        } else {
                            keyString = key
                            isRecording = false
                        }
                    },
                    onCancel: {
                        isRecording = false
                    }
                )
                .frame(width: 1, height: 1)
                .opacity(0)
            }
        } else {
            Button(AppSettings.displayString(for: keyString)) {
                isRecording = true
            }
            .buttonStyle(.bordered)
        }
    }
}
