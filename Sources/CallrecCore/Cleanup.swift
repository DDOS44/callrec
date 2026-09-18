import Foundation

/// A local language model pass over the raw speech-to-text, which is what
/// makes the difference between "readable" and "technically correct".
///
/// Whisper hears sounds; it does not know that "dohajaar" is "do hazaar" or
/// that "aded" was "added". A small instruct model fixes the spelling,
/// punctuation and stutters without changing what was said.
public enum Cleanup {

    public static let systemPrompt = """
    You clean up raw speech-to-text of an Indian sales phone call. The text is Hinglish written in \
    Roman script. Rewrite it so a human reads it easily: fix misspelled Hindi words into standard \
    Roman Hinglish (hoon, hai, nahi, theek, kya, kitna, karna), restore English words that were \
    transcribed phonetically (bank, amount, check, recruitment, client, meeting, Thursday), add \
    punctuation, remove stutters and repeated words, keep the speaker labels and timestamps exactly, \
    keep the meaning, do not translate to English, do not add anything. Names: Devansh, Anurag, \
    Blaxify. Output only the cleaned lines.
    """

    /// `[mm:ss] Them: text`, one line per segment - the shape the model sees.
    public static func render(_ segments: [Segment]) -> String {
        segments.map { seg in
            let stamp = String(format: "%02d:%02d", Int(seg.start) / 60, Int(seg.start) % 60)
            let who = seg.speaker == .unknown ? "" : "\(seg.speaker.label): "
            return "[\(stamp)] \(who)\(seg.text)"
        }.joined(separator: "\n")
    }

    /// Reads the model's reply back onto the original segments.
    ///
    /// Anything that does not line up one-for-one is discarded in favour of the
    /// raw text: a cleanup pass must never lose or invent a line.
    /// llama.cpp prints its own end markers into stdout; they are not transcript.
    static let endMarkers = ["[end of text]", "<|im_end|>", "</s>", "[end]"]

    static func stripMarkers(_ text: String) -> String {
        var out = text
        for marker in endMarkers {
            out = out.replacingOccurrences(of: marker, with: "", options: .caseInsensitive)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    public static func parse(_ reply: String, original: [Segment]) -> [Segment] {
        let lines = stripMarkers(reply).components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("[") }
        guard lines.count == original.count else { return original }

        return zip(original, lines).map { segment, line in
            guard let close = line.firstIndex(of: "]") else { return segment }
            let stamp = String(line[line.index(after: line.startIndex)..<close])
            guard stamp == String(format: "%02d:%02d", Int(segment.start) / 60, Int(segment.start) % 60) else {
                return segment
            }
            var text = stripMarkers(String(line[line.index(after: close)...]))
            for speaker in [Speaker.me, .them] {
                for prefix in ["**\(speaker.label):**", "\(speaker.label):"] where text.hasPrefix(prefix) {
                    text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                }
            }
            guard !text.isEmpty else { return segment }
            return Segment(start: segment.start, end: segment.end, text: text, speaker: segment.speaker)
        }
    }

    public static var binary: String? {
        Shell.which("llama-completion") ?? Shell.which("llama-cli")
    }

    /// Runs the cleanup. Returns the original transcript on any problem: a
    /// missing model, a timeout, or a reply that does not match line for line.
    public static func run(segments: [Segment], config: Config, timeout: TimeInterval = 120) -> [Segment] {
        guard config.cleanup, !segments.isEmpty else { return segments }
        guard let binary else {
            print("[callrec] transcript cleanup skipped: llama.cpp not installed (brew install llama.cpp)")
            return segments
        }
        guard FileManager.default.fileExists(atPath: config.cleanupModelURL.path) else {
            print("[callrec] transcript cleanup skipped: model missing, run ~/.callrec/download-model.sh")
            return segments
        }

        let prompt = """
        <|im_start|>system
        \(systemPrompt)<|im_end|>
        <|im_start|>user
        \(render(segments))<|im_end|>
        <|im_start|>assistant

        """

        let started = Date()
        guard let result = try? Shell.run(binary, [
            "-m", config.cleanupModelURL.path,
            "-p", prompt,
            "-n", "2048", "--temp", "0.2", "-c", "8192",
            "-no-cnv", "--no-display-prompt", "-st"
        ], timeout: timeout), result.status == 0 else {
            print("[callrec] transcript cleanup failed or timed out, keeping the raw transcript")
            return segments
        }

        let cleaned = parse(result.stdout, original: segments)
        let seconds = Date().timeIntervalSince(started)
        if cleaned == segments || cleaned.map(\.text) == segments.map(\.text) {
            print(String(format: "[callrec] cleanup made no usable change (%.0fs)", seconds))
        } else {
            print(String(format: "[callrec] transcript cleaned in %.0fs", seconds))
        }
        return cleaned
    }
}

extension Segment: Equatable {
    public static func == (a: Segment, b: Segment) -> Bool {
        a.start == b.start && a.end == b.end && a.text == b.text && a.speaker == b.speaker
    }
}
