import Foundation

enum LRCParser {
    enum ParseError: Error { case tooLarge, enhancedLRC }
    static func parse(_ input: String) throws -> LyricsDocument {
        guard input.utf8.count <= 1_048_576 else { throw ParseError.tooLarge }
        let enhanced = try NSRegularExpression(pattern: #"<\d+:\d{2}(?:\.\d+)?>"#)
        guard enhanced.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) == nil else { throw ParseError.enhancedLRC }
        let timestamp = try NSRegularExpression(pattern: #"\[(\d{2,}):(\d{2})(?:\.(\d{1,3}))?\]"#)
        let offset = try NSRegularExpression(pattern: #"^\[offset:([+-]?\d+)\]$"#, options: .caseInsensitive)
        let metadata = try NSRegularExpression(pattern: #"^\[(ar|ti|al|by|re|ve|length):.*\]$"#, options: .caseInsensitive)
        var document = LyricsDocument()
        var entries: [(Double, String, Int)] = []
        let input = input.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n")
        for raw in input.components(separatedBy: .newlines) {
            let line = raw.trimmed
            if line.isEmpty { continue }
            let range = NSRange(line.startIndex..., in: line)
            if let match = offset.firstMatch(in: line, range: range), let r = Range(match.range(at: 1), in: line), let value = Int(line[r]), abs(Double(value)) <= 86_400_000 {
                document.offsetMS = value; continue
            }
            if metadata.firstMatch(in: line, range: range) != nil { continue }
            let matches = timestamp.matches(in: line, range: range)
            guard !matches.isEmpty else { document.invalidLines += 1; continue }
            var cursor = 0, times: [Double] = [], valid = true
            for match in matches {
                guard match.range.location == cursor,
                      let m = Range(match.range(at: 1), in: line), let s = Range(match.range(at: 2), in: line),
                      let minutes = Double(line[m]), let seconds = Double(line[s]), seconds < 60 else { valid = false; break }
                let fraction = Range(match.range(at: 3), in: line).flatMap { Double("0." + line[$0]) } ?? 0
                let time = minutes * 60 + seconds + fraction
                guard time.isFinite, time <= 86_400 else { valid = false; break }
                times.append(time); cursor = NSMaxRange(match.range)
            }
            guard valid, let textRange = Range(NSRange(location: cursor, length: range.length - cursor), in: line) else { document.invalidLines += 1; continue }
            let text = String(line[textRange]).trimmed
            guard !text.hasPrefix("[") else { document.invalidLines += 1; continue }
            for time in times { entries.append((time, text, entries.count)) }
            guard entries.count <= 10_000 else { throw ParseError.tooLarge }
        }
        entries.sort { $0.0 == $1.0 ? $0.2 < $1.2 : $0.0 < $1.0 }
        for (time, text, _) in entries {
            if let last = document.cues.last, last.start == time {
                if !last.texts.contains(text) { document.cues[document.cues.count - 1].texts.append(text) }
            } else { document.cues.append(LyricCue(id: document.cues.count, start: time, texts: [text])) }
        }
        return document
    }
}
