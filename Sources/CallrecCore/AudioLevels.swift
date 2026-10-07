import AVFoundation
import Foundation

public enum AudioLevels {
    /// One RMS value per second of a wav file.
    public static func perSecond(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(format.sampleRate)
        var out: [Float] = []
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
            try file.read(into: buf, frameCount: frames)
            if buf.frameLength == 0 { break }
            var sum: Double = 0
            var count = 0
            if let channels = buf.floatChannelData {
                for c in 0..<Int(format.channelCount) {
                    for i in 0..<Int(buf.frameLength) {
                        let v = Double(channels[c][i]); sum += v * v; count += 1
                    }
                }
            }
            out.append(count > 0 ? Float((sum / Double(count)).squareRoot()) : 0)
        }
        return out
    }
}
