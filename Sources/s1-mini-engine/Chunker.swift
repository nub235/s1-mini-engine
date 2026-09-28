import Foundation

// --- SENTENCE-AWARE CHUNKING ---
//
// Why chunk at all: this model was trained on short (roughly <=1000-token) inputs
// and its quality degrades on very long ones, so splitting into training-scale
// pieces is both a context-safety win and a quality win. Pieces are cut at
// sentence boundaries so the model never sees half a sentence.
//
// Why no overlap: an overlap would hand the model text it already normalized, and
// it would happily reproduce it, duplicating sentences at every seam. Each piece
// is therefore normalized independently and stitched with the separator that was
// present at the split point.
enum Chunker {
    /// Target size of a single enhancement pass, in characters. Roughly 1000
    /// tokens for English, which sits well inside the model's 4096-token context
    /// once the generation budget is accounted for.
    static let singleChunkCap = 4000

    /// Hard ceiling on a single request, in characters. Beyond this the server
    /// rejects and the CLI truncates.
    static let totalCap = 32000

    /// Split `text` into enhancement-ready pieces, re-attaching any leading
    /// [Styling: ...] control line to every piece. `separatorAfter` is the
    /// whitespace that appeared between this piece and the next.
    static func plan(_ text: String) -> [(text: String, separatorAfter: String)] {
        let (control, body) = splitControl(text)
        var pieces = splitBody(body)
        if pieces.isEmpty { pieces = [(body.trimmingCharacters(in: .whitespacesAndNewlines), "")] }
        guard let c = control else { return pieces }
        return pieces.map { (c + "\n" + $0.text, $0.separatorAfter) }
    }

    /// A leading "[Styling: ...]" line is a control line, not transcript.
    static func splitControl(_ text: String) -> (control: String?, body: String) {
        guard text.hasPrefix("[Styling:") else { return (nil, text) }
        guard let nl = text.firstIndex(of: "\n") else { return (text, "") }
        let line = String(text[text.startIndex..<nl])
        let rest = String(text[text.index(after: nl)...])
        return (line, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func splitBody(_ body: String) -> [(text: String, separatorAfter: String)] {
        let chars = Array(body)
        guard chars.count > singleChunkCap else {
            let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [(t, "")]
        }
        var result: [(text: String, separatorAfter: String)] = []
        var start = 0
        while start < chars.count {
            if chars.count - start <= singleChunkCap {
                let tail = String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { result.append((tail, "")) }
                break
            }
            let hardEnd = start + singleChunkCap
            let floor = start + singleChunkCap / 2
            var split = -1
            var sep = " "
            var i = hardEnd - 1
            while i > floor {
                let c = chars[i]
                if c == "." || c == "!" || c == "?" {
                    split = i + 1
                    sep = " "
                    break
                }
                if c == "\n" {
                    split = i + 1
                    sep = "\n"
                    break
                }
                i -= 1
            }
            if split < 0 {
                // no sentence boundary in the window: fall back to the last space
                var j = hardEnd - 1
                while j > floor {
                    if chars[j] == " " { split = j; sep = " "; break }
                    j -= 1
                }
            }
            if split < 0 { split = hardEnd; sep = " " }   // pathological: hard cut
            let piece = String(chars[start..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append((piece, sep)) }
            start = split
            while start < chars.count && (chars[start] == " " || chars[start] == "\n") { start += 1 }
        }
        if let last = result.last {
            result[result.count - 1] = (last.text, "")
        }
        return result
    }
}

extension SpecStats {
    /// Sum two per-request stat blocks so a chunked request reports as one run.
    static func + (lhs: SpecStats, rhs: SpecStats) -> SpecStats {
        var s = SpecStats()
        s.promptTokens = lhs.promptTokens + rhs.promptTokens
        s.verifiedTokens = lhs.verifiedTokens + rhs.verifiedTokens
        s.divergences = lhs.divergences + rhs.divergences
        s.autoregressiveTokens = lhs.autoregressiveTokens + rhs.autoregressiveTokens
        s.rejectedDrafts = lhs.rejectedDrafts + rhs.rejectedDrafts
        s.cycles = lhs.cycles + rhs.cycles
        s.naiveCycles = lhs.naiveCycles + rhs.naiveCycles
        s.serialCycles = lhs.serialCycles + rhs.serialCycles
        s.runCycles = lhs.runCycles + rhs.runCycles
        s.prefillUs = lhs.prefillUs + rhs.prefillUs
        s.prefillCached = lhs.prefillCached + rhs.prefillCached
        s.prefillEvaluated = lhs.prefillEvaluated + rhs.prefillEvaluated
        s.verifyUs = lhs.verifyUs + rhs.verifyUs
        s.decodeUs = lhs.decodeUs + rhs.decodeUs
        s.events = lhs.events + rhs.events
        return s
    }
}

/// Enhance arbitrary-length text: split at sentence boundaries, run each piece
/// through the engine, and stitch the results with the original separators.
/// `emit`, when provided, receives output pieces as they finalize (for streaming).
func enhanceLongText(_ text: String,
                     naive: Bool,
                     emit: ((String) -> Void)? = nil) -> (output: String, stats: SpecStats) {
    let planned = Chunker.plan(text)
    if planned.count <= 1 {
        return enhanceTranscript(text, naive: naive, emit: emit)
    }
    var out = ""
    var total = SpecStats()
    for (i, piece) in planned.enumerated() {
        if i > 0 {
            let sep = planned[i - 1].separatorAfter
            out += sep
            emit?(sep)
        }
        let r = enhanceTranscript(piece.text, naive: naive, emit: emit)
        out += r.output
        total = total + r.stats
    }
    return (out, total)
}
