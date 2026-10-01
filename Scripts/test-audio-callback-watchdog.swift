import Foundation

// Run with:
// swiftc Sources/SoundScape/AudioCallbackWatchdog.swift Scripts/test-audio-callback-watchdog.swift -o /tmp/soundscape-watchdog-test
// /tmp/soundscape-watchdog-test
@main
enum AudioCallbackWatchdogTests {
    static func main() {
        let microphone = AudioCallbackWatchdog()
        precondition(!microphone.isStalled(now: 100), "Unstarted inputs must not recover")
        microphone.arm(now: 100)
        precondition(!microphone.isStalled(now: 105), "Allow startup grace period")
        precondition(microphone.isStalled(now: 105.1), "Detect a device that never starts callbacks")

        // Silence still produces callbacks; volume must not affect health.
        for second in 101...120 {
            microphone.recordCallback(now: Double(second))
            precondition(!microphone.isStalled(now: Double(second) + 0.5))
        }
        precondition(microphone.isStalled(now: 126), "Detect loss after healthy capture")

        let otherInput = AudioCallbackWatchdog()
        otherInput.arm(now: 126)
        otherInput.recordCallback(now: 127)
        precondition(microphone.isStalled(now: 127), "Other sources must not mask a dead microphone")
        precondition(!otherInput.isStalled(now: 127))

        microphone.arm(now: 200)
        precondition(!microphone.isStalled(now: 201), "Recovery must reset the grace period")
        print("Audio callback watchdog regression checks passed")
    }
}
