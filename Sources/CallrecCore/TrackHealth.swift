import AVFoundation
import Foundation

/// Detects a track that carries no signal at all. macOS hands a process zeros
/// (not an error) when the microphone permission is not effective for it, so a
/// "recorded" mic track can be pure digital silence and nothing else notices.
public enum TrackHealth {
    /// A track whose loudest sample is below this is treated as not recorded.
    /// Real rooms never get near it: a quiet room is around -60 dBFS.
    public static let silentBelowDBFS: Float = -90

    public static let micWarning = "your microphone was not recorded (silent track)"
    public static let farWarning = "the other side was not recorded (silent track)"
    public static let micLogLine = "WARNING: mic track is silent for the entire call — microphone permission is probably not effective. System Settings → Privacy & Security → Microphone → callrec"
    public static let farLogLine = "WARNING: system-audio track is silent for the entire call — system audio recording permission is probably not effective. System Settings → Privacy & Security → Screen & System Audio Recording → callrec"

    /// Peak level in dBFS. `-infinity` for no samples or all zeros.
    public static func peakDBFS(_ samples: [Float]) -> Float {
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        return dbfs(peak: peak)
    }

    public static func dbfs(peak: Float) -> Float {
        peak > 0 ? 20 * log10(peak) : -Float.infinity
    }

    public static func isSilent(peakDBFS: Float) -> Bool { peakDBFS < silentBelowDBFS }

    /// Pure classifier: all zeros (or below -90 dBFS) for the whole track is silent.
    public static func isSilent(samples: [Float]) -> Bool { isSilent(peakDBFS: peakDBFS(samples)) }

    /// Streams a wav and returns its peak, so a long call is never loaded whole.
    public static func peakDBFS(url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate)
        var peak: Float = 0
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: buf, frameCount: chunk)
            if buf.frameLength == 0 { break }
            if let channels = buf.floatChannelData {
                for c in 0..<Int(format.channelCount) {
                    for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(channels[c][i])) }
                }
            }
        }
        return dbfs(peak: peak)
    }

    public struct Report: Equatable {
        public var micSilent = false
        public var farSilent = false
        public init(micSilent: Bool = false, farSilent: Bool = false) {
            self.micSilent = micSilent
            self.farSilent = farSilent
        }
        /// The `- warning:` header values for this report.
        public var warnings: [String] {
            (micSilent ? [TrackHealth.micWarning] : []) + (farSilent ? [TrackHealth.farWarning] : [])
        }
    }

    /// Measures both finished tracks. A track that cannot be read is logged and
    /// not called silent: this check must never invent a warning.
    public static func check(paths: RecordingPaths) -> Report {
        var report = Report()
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.micWav.path),
           let peak = attempt("could not measure the mic track level", { try peakDBFS(url: paths.micWav) }) {
            report.micSilent = isSilent(peakDBFS: peak)
        }
        if fm.fileExists(atPath: paths.farWav.path),
           let peak = attempt("could not measure the system-audio track level", { try peakDBFS(url: paths.farWav) }) {
            report.farSilent = isSilent(peakDBFS: peak)
        }
        return report
    }

    /// Logs the loud warning for each silent track.
    public static func logWarnings(_ report: Report, id: String) {
        if report.micSilent { logError("\(id): \(micLogLine)", .capture) }
        if report.farSilent { logError("\(id): \(farLogLine)", .capture) }
    }
}
