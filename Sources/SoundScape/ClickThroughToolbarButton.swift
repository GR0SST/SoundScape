import AppKit
import SwiftUI

struct ClickThroughToolbarButton: NSViewRepresentable {
    enum Appearance {
        case navigation
        case transport(isRunning: Bool)
    }

    let title: String?
    let systemImage: String
    let accessibilityLabel: String
    let appearance: Appearance
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> FirstMouseButton {
        let button = FirstMouseButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        button.isBordered = false
        button.focusRingType = .none
        button.wantsLayer = true
        update(button)
        return button
    }

    func updateNSView(
        _ button: FirstMouseButton,
        context: Context
    ) {
        context.coordinator.action = action
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        update(button)
    }

    private func update(_ button: FirstMouseButton) {
        let image = NSImage(
            systemSymbolName: systemImage,
            accessibilityDescription: nil
        )
        let symbolSize: CGFloat
        switch appearance {
        case .navigation:
            symbolSize = 13
        case .transport:
            symbolSize = 10
        }
        button.image = image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(
                pointSize: symbolSize,
                weight: .bold
            )
        )
        button.imagePosition = title == nil ? .imageOnly : .imageLeading
        button.imageScaling = .scaleNone
        button.imageHugsTitle = true
        button.alignment = .center
        button.setAccessibilityLabel(accessibilityLabel)

        switch appearance {
        case .navigation:
            button.font = .systemFont(ofSize: 13, weight: .bold)
            button.contentTintColor = .white
            button.layer?.backgroundColor =
                NSColor.white.withAlphaComponent(0.055).cgColor
            button.layer?.cornerRadius = 6

        case .transport(let isRunning):
            button.font = .systemFont(ofSize: 12, weight: .bold)
            button.contentTintColor = NSColor(
                calibratedRed: 0.03,
                green: 0.10,
                blue: 0.12,
                alpha: 1
            )
            button.layer?.backgroundColor = NSColor(
                calibratedRed: isRunning ? 0.25 : 0.20,
                green: isRunning ? 0.86 : 0.80,
                blue: isRunning ? 0.68 : 0.95,
                alpha: 1
            ).cgColor
            button.layer?.cornerRadius = 7
        }

        if let title,
           let font = button.font,
           let color = button.contentTintColor {
            button.attributedTitle = NSAttributedString(
                string: "\u{2002}\(title)",
                attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .baselineOffset: -1
                ]
            )
        } else {
            button.title = ""
        }
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            let action = action
            DispatchQueue.main.async {
                action()
            }
        }
    }
}

final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
