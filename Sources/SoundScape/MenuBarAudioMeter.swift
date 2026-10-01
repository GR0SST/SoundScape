import AppKit
import SwiftUI

/// Redraws only the tiny status image, using existing output meters (no audio tap).
@MainActor
final class MenuBarAudioMeter: ObservableObject {
    @Published private(set) var image = MenuBarAudioMeter.makeImage(level: 0, phase: 0)
    private var target: Double = 0
    private var level: Double = 0
    private var timer: Timer?
    private var visible = true
    private var phase: Double = 0

    func setLevel(_ decibels: Double) {
        // Ignore the noise floor and give ordinary speech a useful visual range.
        target = decibels.isFinite ? min(max((decibels + 60) / 52, 0), 1) : 0
        guard visible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopTimer()
            level = target
            image = Self.makeImage(level: level, phase: 0)
        } else if timer == nil, target > 0 || level > 0 {
            let timer = Timer(timeInterval: 1.0 / 24, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        if visible {
            setLevel(target * 52 - 60)
        } else {
            stopTimer()
        }
    }

    private func tick() {
        guard visible else { stopTimer(); return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Fast attack, slower release: voice peaks react quickly without flicker.
        level += (target - level) * (target > level ? 0.65 : 0.18)
        if reduceMotion { level = target }
        if target == 0, level < 0.005 { level = 0 }
        phase += 0.34
        image = Self.makeImage(level: level, phase: reduceMotion ? 0 : phase)
        if reduceMotion || (target == 0 && level == 0) { stopTimer() }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    private static func makeImage(level: Double, phase: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            let idle: [Double] = [3, 6, 10, 6, 3]
            let envelope: [Double] = [0.55, 0.85, 1, 0.85, 0.55]
            for index in 0..<5 {
                let movement = 0.76 + 0.24 * sin(phase + Double(index) * 1.7)
                let peak = 3 + 13 * envelope[index] * movement
                let height = idle[index] * (1 - level) + peak * level
                let bar = NSRect(x: 1 + Double(index) * 3.5,
                                 y: (rect.height - height) / 2,
                                 width: 2, height: height)
                NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SoundScape"
        return image
    }
}

struct MenuBarAudioIcon: View {
    @ObservedObject var meter: MenuBarAudioMeter

    var body: some View {
        Image(nsImage: meter.image)
            .accessibilityLabel("SoundScape")
            .onAppear { meter.setVisible(true) }
            .onDisappear { meter.setVisible(false) }
    }
}
