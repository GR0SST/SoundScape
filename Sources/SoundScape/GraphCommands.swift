import AppKit
import SwiftUI

@MainActor
func dismissTextInputFocus() {
    guard NSApp.keyWindow?.firstResponder is NSTextView else { return }
    NSApp.keyWindow?.makeFirstResponder(nil)
}

enum WorkspaceTextFocus: Hashable {
    case sessionName
    case librarySearch
    case parameterSearch
    case recorderFileName
}

struct GraphCommandActions {
    let canCopy: Bool
    let canPaste: Bool
    let copy: () -> Void
    let paste: () -> Void
    let delete: () -> Void
    let canUndo: Bool
    let canRedo: Bool
    let undo: () -> Void
    let redo: () -> Void
}

private struct GraphCommandActionsKey: FocusedValueKey {
    typealias Value = GraphCommandActions
}

extension FocusedValues {
    var graphCommandActions: GraphCommandActions? {
        get { self[GraphCommandActionsKey.self] }
        set { self[GraphCommandActionsKey.self] = newValue }
    }
}

struct GraphPasteboardCommands: Commands {
    @FocusedValue(\.graphCommandActions) private var graphActions

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                if !sendToTextResponder(Selector(("undo:"))) {
                    graphActions?.undo()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(graphActions != nil && graphActions?.canUndo == false)

            Button("Redo") {
                if !sendToTextResponder(Selector(("redo:"))) {
                    graphActions?.redo()
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(graphActions != nil && graphActions?.canRedo == false)
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Copy") {
                if !sendToTextResponder(#selector(NSText.copy(_:))) {
                    graphActions?.copy()
                }
            }
            .keyboardShortcut("c", modifiers: .command)

            Button("Paste") {
                if !sendToTextResponder(#selector(NSText.paste(_:))) {
                    graphActions?.paste()
                }
            }
            .keyboardShortcut("v", modifiers: .command)

            Divider()

            Button("Delete Nodes") {
                if !sendToTextResponder(#selector(NSText.deleteBackward(_:))) {
                    graphActions?.delete()
                }
            }
            .keyboardShortcut(.delete, modifiers: [])

            Button("Delete Nodes Forward") {
                if !sendToTextResponder(#selector(NSText.deleteForward(_:))) {
                    graphActions?.delete()
                }
            }
            .keyboardShortcut(.deleteForward, modifiers: [])
        }
    }

    private func sendToTextResponder(_ action: Selector) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSTextView else { return false }
        return NSApp.sendAction(action, to: nil, from: nil)
    }
}
