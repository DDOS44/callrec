import Foundation

/// Multi-channel → mono for the microphone.
///
/// During a call macOS switches the MacBook's built-in mic from a 1-channel input to a
/// 3-channel one (the mic array, used by the call's voice processing), and some of those
/// channels carry nothing. Letting AVAudioConverter pick channels for a 3-channel input
/// with no layout produced pure digital silence for the whole call — while the same mic
/// recorded fine (-6.6 dBFS) outside a call. Verified 2026-10-07. So: average only the
/// channels that actually carry signal in this buffer.
public enum Downmix {
    /// A channel counts as active if its peak is above this (≈ -96 dBFS).
    public static let activeFloor: Float = 0.000_016

    /// Average of the channels that carry signal. If none do, returns silence.
    public static func activeAverage(_ channels: [[Float]]) -> [Float] {
        guard let frames = channels.first?.count else { return [] }
        let active = channels.filter { ch in ch.contains { abs($0) > activeFloor } }
        guard !active.isEmpty else { return [Float](repeating: 0, count: frames) }
        if active.count == 1 { return active[0] }
        var out = [Float](repeating: 0, count: frames)
        for ch in active {
            for i in 0..<min(frames, ch.count) { out[i] += ch[i] }
        }
        let n = Float(active.count)
        for i in 0..<frames { out[i] /= n }
        return out
    }

    /// Which channel indices carried signal (for a one-line diagnostic log).
    public static func activeChannels(_ channels: [[Float]]) -> [Int] {
        channels.enumerated().filter { _, ch in ch.contains { abs($0) > activeFloor } }.map(\.offset)
    }
}
