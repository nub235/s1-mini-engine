import llama
import Foundation
import Darwin

// --- CONFIG / ARGUMENT PARSING ---
//
// Modes (auto-detected unless forced):
//   s1-mini-engine <model.gguf> "<transcript>"   one-shot: enhance, print, exit
//   echo "..." | s1-mini-engine <model.gguf>      one-shot from piped stdin
//   s1-mini-engine <model.gguf>                   interactive REPL (stdin is a terminal)
//   s1-mini-engine <model.gguf> --http            OpenAI-compatible HTTP server
//   s1-mini-engine pull                           download the weights (see Puller.swift)
//
// Flags: -i/--repl, --naive, --verify, --max-tokens N, --http, --host H,
//        --port N, --prompt "..." (alias for a positional transcript), -h/--help

let programName = "s1-mini-engine"
// versionString lives in Version.swift so release tooling has one place to read.

// Generation budget per request. The context is 4096 tokens (from the GGUF) and
// the model was trained on inputs of roughly <=1024 tokens, so 2048 output
// tokens leaves ample headroom for the longest supported (4000-char) input.
var maxTokens = 2048

func printUsage() {
    print("""
    \(programName) \(versionString) — local text normalizer for ASR transcripts (Superwhisper S1-mini)

    USAGE:
      \(programName) [options] [model.gguf] [transcript]
      \(programName) pull [--model Q6_K|Q8_0|F16] [--dir PATH]   download weights

    MODES (auto-detected):
      transcript given (argument or piped stdin)   enhance once, print, exit
      no transcript + terminal stdin               interactive REPL
      --http                                       OpenAI-compatible API server
      pull (as the first argument)                 download the GGUF weights

    OPTIONS:
      -i, --repl              force the interactive REPL
          --naive             plain autoregressive decoding (use for raw,
                              unpunctuated ASR input, where speculation loses)
          --verify            run naive + speculative and assert identical output
          --stats             print decode/timing counters to stderr (for benchmarks;
                              the REPL prints the same line to stdout)
          --max-tokens N      max generated tokens per request (default \(maxTokens))
          --http              run the OpenAI-compatible HTTP server
          --host H            bind address for --http (default 127.0.0.1)
          --port N            port for --http (default 8080)
          --prompt "TEXT"     alias for supplying the transcript as an argument
      -h, --help              show this help
          --version           print version and exit

    The model path may be omitted when the GGUF is found via $S1_MINI_MODEL or at
    ./s1-mini-Q6_K.gguf, ./models/s1-mini-Q6_K.gguf, or in ~/.cache/s1-mini/ (where
    `\(programName) pull` puts it).
    """)
}

/// Resolve the GGUF to load: explicit argument first, then $S1_MINI_MODEL, then
/// a GGUF sitting in the working tree, then the cache directory `pull` writes to
/// (see Puller.swift for why Q6_K is checked first).
func resolveModelPath(explicit: String?) -> String? {
    let fm = FileManager.default
    if let e = explicit { return fm.fileExists(atPath: e) ? e : nil }
    if let env = ProcessInfo.processInfo.environment["S1_MINI_MODEL"], fm.fileExists(atPath: env) {
        return env
    }
    let home = NSHomeDirectory()
    let cache = "\(home)/.cache/s1-mini"
    let candidates = [
        "s1-mini-Q6_K.gguf",
        "q6.gguf",
        "models/s1-mini-Q6_K.gguf",
        "models/q6.gguf",
    ] + pullChoices.map { name in
        // Q6_K first: it is the recommended export and the one `pull` defaults to.
        "\(cache)/s1-mini-\(name).gguf"
    }
    for c in candidates where fm.fileExists(atPath: c) { return c }
    return nil
}

var verifyMode = false
var statsMode = false
var naiveMode = false
var replForced = false
var httpMode = false
var httpHost = "127.0.0.1"
var httpPort: UInt16 = 8080
var explicitModel: String? = nil
var promptText: String? = nil

let rawArgs = Array(CommandLine.arguments.dropFirst())

// `pull` is a subcommand, not a transcript, so it runs before the parser below
// (which would otherwise read the word as input text) and before any model load.
// A transcript that is literally the word "pull" is still reachable via
// `--prompt "pull"`.
if rawArgs.first == "pull" {
    runPull(Array(rawArgs.dropFirst()))
}

var argIdx = 0
var passthrough = false
var unknownArgs: [String] = []
while argIdx < rawArgs.count {
    let arg = rawArgs[argIdx]
    func value(_ flag: String) -> String {
        argIdx += 1
        guard argIdx < rawArgs.count else {
            FileHandle.standardError.write(Data("Error: \(flag) requires a value\n".utf8))
            exit(2)
        }
        return rawArgs[argIdx]
    }
    func positional(_ arg: String) {
        if explicitModel == nil && (arg.hasSuffix(".gguf") || FileManager.default.fileExists(atPath: arg)) {
            explicitModel = arg
        } else {
            promptText = promptText.map { $0 + " " + arg } ?? arg
        }
    }
    if passthrough {
        positional(arg)
        argIdx += 1
        continue
    }
    switch arg {
    case "--":          passthrough = true
    case "-h", "--help": printUsage(); exit(0)
    case "--version":    print("\(programName) \(versionString)"); exit(0)
    case "-i", "--repl", "--interactive": replForced = true
    case "--naive":      naiveMode = true
    case "--verify":     verifyMode = true
    case "--stats":      statsMode = true
    case "--http":       httpMode = true
    case "--host":       httpHost = value("--host")
    case "--port":
        guard let p = UInt16(value("--port")) else {
            FileHandle.standardError.write(Data("Error: --port must be a number\n".utf8)); exit(2)
        }
        httpPort = p
    case "--max-tokens":
        guard let n = Int(value("--max-tokens")), n > 0 else {
            FileHandle.standardError.write(Data("Error: --max-tokens must be a positive integer\n".utf8)); exit(2)
        }
        maxTokens = n
    case "--prompt":     promptText = value("--prompt")
    default:
        if arg.hasPrefix("-") { unknownArgs.append(arg) } else { positional(arg) }
    }
    argIdx += 1
}
if !unknownArgs.isEmpty {
    FileHandle.standardError.write(Data("Warning: ignoring unknown option(s): \(unknownArgs.joined(separator: " "))\n".utf8))
}

let modelPath: String = {
    guard let p = resolveModelPath(explicit: explicitModel) else {
        FileHandle.standardError.write(Data("Error: no GGUF model found. Pass a path, set $S1_MINI_MODEL, or run `\(programName) pull`\n".utf8))
        printUsage()
        exit(1)
    }
    return p
}()

// Read the transcript from piped stdin when no explicit text was supplied.
if promptText == nil && !replForced && !httpMode && isatty(STDIN_FILENO) == 0 {
    var piped = ""
    while let line = readLine(strippingNewline: false) { piped += line }
    let t = piped.trimmingCharacters(in: .whitespacesAndNewlines)
    if !t.isEmpty { promptText = t }
}

// An explicit transcript (argument or stdin) wins unless the REPL or server was
// forced; otherwise a terminal stdin drops into the REPL.
let replMode = !httpMode && (replForced || promptText == nil)
let showBanner = replMode || httpMode

// The normalization instruction and reasoning behavior are embedded in
// tokenizer.chat_template inside the GGUF. The low-level llama.h API used
// here cannot execute arbitrary Jinja templates, so the prompt below mirrors
// the fixed behavior of this specific embedded template without duplicating
// a separate systemPrompt configuration variable.
let defaultControl = "[Styling: semi-formal] [Structure: lists] [Context: general]"

// --- SUPPRESS LLAMA.CPP INTERNAL LOGGING ---
llama_log_set({ _, _, _ in }, nil)

// --- INIT BACKEND (once per process) ---
ggml_time_init()
llama_backend_init()
defer { llama_backend_free() }

// --- LOAD MODEL (once per process) ---
// model/context are declared as top-level `let` globals (not `guard let` locals)
// so the generation functions here and in other files can reference them without
// running into closure-capture restrictions.
var modelParams = llama_model_default_params()
modelParams.n_gpu_layers = 999 // offload everything to Metal

let loadStart = ggml_time_us()
let model: OpaquePointer = {
    if showBanner {
        print("Loading \(modelPath) ...", terminator: "")
        fflush(stdout)
    }
    guard let m = llama_model_load_from_file(modelPath, modelParams) else {
        print("\nFailed to load model at \(modelPath)")
        exit(1)
    }
    return m
}()
defer { llama_model_free(model) }

let vocab = llama_model_get_vocab(model)

var ctxParams = llama_context_default_params()
ctxParams.n_ctx = 0       // use context length from GGUF metadata
ctxParams.n_batch = 1024

let context: OpaquePointer = {
    guard let c = llama_init_from_model(model, ctxParams) else {
        print("\nFailed to create context")
        exit(1)
    }
    return c
}()
defer { llama_free(context) }
let loadEnd = ggml_time_us()
let loadSeconds = Double(loadEnd - loadStart) / 1_000_000.0
if showBanner {
    print(String(format: " %.2fs", loadSeconds))
}
if replMode {
    print()
    print(String(repeating: "=", count: 60))
    print("Session ready — type transcript to enhance.")
    print("Default control: \(defaultControl)")
    print("Tip: you can override by starting your input with [Styling: ...]")
    print("Commands: /quit, /exit, /q to exit | /help for help")
    print(String(repeating: "=", count: 60))
    print("")
}

// MARK: - Line editor with raw mode (fixes 900-char paste limit & arrow/backspace editing)

private struct LineHistory {
    static var entries: [String] = []
    static var saved: String = ""
}

private func enableRawMode() -> termios? {
    var orig = termios()
    guard tcgetattr(STDIN_FILENO, &orig) == 0 else { return nil }
    var raw = orig
    raw.c_iflag &= ~UInt(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
    raw.c_oflag &= ~UInt(OPOST)
    raw.c_cflag |= UInt(CS8)
    raw.c_lflag &= ~UInt(ECHO | ICANON | IEXTEN | ISIG)
    withUnsafeMutablePointer(to: &raw.c_cc) { ptr in
        let cc = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        cc[Int(VMIN)] = 1
        cc[Int(VTIME)] = 1 // 100ms timeout for ESC sequence disambiguation
    }
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    return orig
}

private func disableRawMode(_ orig: termios) {
    var o = orig
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &o)
}

/// Read a line with full editing support: arrows, backspace/delete, home/end, Ctrl-A/E/B/F/K/U/W, history, bracketed paste.
/// Falls back to readLine if stdin is not a TTY. Supports up to 4000 characters.
private func readLineWithEditing(prompt: String) -> String? {
    guard isatty(STDIN_FILENO) != 0 else {
        print(prompt, terminator: "")
        fflush(stdout)
        return readLine(strippingNewline: true)
    }
    guard let orig = enableRawMode() else {
        print(prompt, terminator: "")
        fflush(stdout)
        return readLine(strippingNewline: true)
    }
    defer { disableRawMode(orig) }

    // Enable bracketed paste so multiline pastes don't submit mid-paste
    let enablePaste: [UInt8] = [0x1B, 91, 63, 50, 48, 48, 52, 104]
    let disablePaste: [UInt8] = [0x1B, 91, 63, 50, 48, 48, 52, 108]
    _ = enablePaste.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress!, $0.count) }
    defer { _ = disablePaste.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress!, $0.count) } }

    FileHandle.standardOutput.write(Data(prompt.utf8))
    fflush(stdout)

    var buffer: [Character] = []
    var cursor = 0
    var historyIdx = LineHistory.entries.count
    var bracketedPaste = false
    var pasteBuffer: [Character] = []

    func refresh() {
        var out = "\r\u{1B}[K" + prompt + String(buffer)
        let back = buffer.count - cursor
        if back > 0 {
            out += "\u{1B}[\(back)D"
        }
        FileHandle.standardOutput.write(Data(out.utf8))
        fflush(stdout)
    }

    while true {
        var byte: UInt8 = 0
        let n = read(STDIN_FILENO, &byte, 1)
        if n < 0 { continue }
        if n == 0 { continue }

        if bracketedPaste {
            if byte == 0x1B {
                var seq: [UInt8] = [byte]
                var tmp: UInt8 = 0
                var matched = true
                let expected: [UInt8] = [91, 50, 48, 49, 126] // "[201~"
                for exp in expected {
                    let r = read(STDIN_FILENO, &tmp, 1)
                    if r <= 0 || tmp != exp {
                        matched = false
                        break
                    }
                    seq.append(tmp)
                }
                if matched {
                    bracketedPaste = false
                    let pasteStr = String(pasteBuffer)
                        .replacingOccurrences(of: "\r\n", with: " ")
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                    let chars = Array(pasteStr)
                    if buffer.count + chars.count <= 4000 {
                        buffer.insert(contentsOf: chars, at: cursor)
                        cursor += chars.count
                    } else {
                        let room = 4000 - buffer.count
                        if room > 0 {
                            buffer.insert(contentsOf: chars.prefix(room), at: cursor)
                            cursor += room
                        }
                    }
                    pasteBuffer.removeAll()
                    refresh()
                    continue
                } else {
                    for b in seq {
                        if b == 0x1B { continue }
                        if b < 0x80 {
                            pasteBuffer.append(Character(UnicodeScalar(b)))
                        }
                    }
                    continue
                }
            } else {
                if byte < 0x80 {
                    if byte == 10 || byte == 13 {
                        pasteBuffer.append(" ")
                    } else if byte >= 32 || byte == 9 {
                        pasteBuffer.append(Character(UnicodeScalar(byte)))
                    }
                } else {
                    let len: Int
                    if byte & 0xE0 == 0xC0 { len = 2 }
                    else if byte & 0xF0 == 0xE0 { len = 3 }
                    else if byte & 0xF8 == 0xF0 { len = 4 }
                    else { len = 1 }
                    var bytes: [UInt8] = [byte]
                    for _ in 1..<len {
                        var nb: UInt8 = 0
                        if read(STDIN_FILENO, &nb, 1) > 0 { bytes.append(nb) }
                    }
                    if let str = String(bytes: bytes, encoding: .utf8) {
                        for ch in str { pasteBuffer.append(ch) }
                    }
                }
                continue
            }
        }

        if byte == 0x1B {
            var s1: UInt8 = 0
            let r1 = read(STDIN_FILENO, &s1, 1)
            if r1 <= 0 { continue }
            if s1 == 91 { // '[' CSI
                var s2: UInt8 = 0
                let r2 = read(STDIN_FILENO, &s2, 1)
                if r2 <= 0 { continue }
                if s2 == 50 { // '2'
                    var s3: UInt8 = 0, s4: UInt8 = 0, s5: UInt8 = 0
                    let r3 = read(STDIN_FILENO, &s3, 1)
                    let r4 = read(STDIN_FILENO, &s4, 1)
                    let r5 = read(STDIN_FILENO, &s5, 1)
                    if r3 > 0 && r4 > 0 && r5 > 0 && s3 == 48 && s4 == 48 && s5 == 126 {
                        bracketedPaste = true
                        pasteBuffer.removeAll()
                        continue
                    }
                    if r3 > 0 && r4 > 0 && r5 > 0 && s3 == 48 && s4 == 49 && s5 == 126 {
                        bracketedPaste = false
                        continue
                    }
                    var b = s5
                    while b < 64 || b > 126 {
                        var nb: UInt8 = 0
                        if read(STDIN_FILENO, &nb, 1) <= 0 { break }
                        b = nb
                        if b >= 64 && b <= 126 { break }
                    }
                    continue
                }
                switch s2 {
                case 65: // Up
                    if historyIdx > 0 {
                        if historyIdx == LineHistory.entries.count { LineHistory.saved = String(buffer) }
                        historyIdx -= 1
                        buffer = Array(LineHistory.entries[historyIdx])
                        cursor = buffer.count
                        refresh()
                    }
                case 66: // Down
                    if historyIdx < LineHistory.entries.count {
                        historyIdx += 1
                        if historyIdx == LineHistory.entries.count {
                            buffer = Array(LineHistory.saved)
                        } else {
                            buffer = Array(LineHistory.entries[historyIdx])
                        }
                        cursor = buffer.count
                        refresh()
                    }
                case 67: // Right
                    if cursor < buffer.count { cursor += 1; refresh() }
                case 68: // Left
                    if cursor > 0 { cursor -= 1; refresh() }
                case 72: // Home
                    cursor = 0; refresh()
                case 70: // End
                    cursor = buffer.count; refresh()
                default:
                    if s2 >= 49 && s2 <= 54 {
                        var extra: [UInt8] = [s2]
                        var term: UInt8 = 0
                        while true {
                            var nb: UInt8 = 0
                            if read(STDIN_FILENO, &nb, 1) <= 0 { break }
                            extra.append(nb)
                            if nb >= 64 && nb <= 126 { term = nb; break }
                            if extra.count > 8 { break }
                        }
                        if extra == [51, 126] { // Delete ESC[3~
                            if cursor < buffer.count {
                                buffer.remove(at: cursor)
                                refresh()
                            }
                        } else if extra == [49, 126] || extra == [55, 126] {
                            cursor = 0; refresh()
                        } else if extra == [52, 126] || extra == [56, 126] {
                            cursor = buffer.count; refresh()
                        } else if term == 126 {
                            // ignore other ~ sequences
                        }
                    }
                }
            } else if s1 == 79 { // ESC O H/F
                var s2b: UInt8 = 0
                if read(STDIN_FILENO, &s2b, 1) > 0 {
                    if s2b == 72 { cursor = 0; refresh() }
                    else if s2b == 70 { cursor = buffer.count; refresh() }
                }
            }
            continue
        }

        switch byte {
        case 10, 13:
            _ = write(STDOUT_FILENO, "\n", 1)
            let str = String(buffer)
            if !str.trimmingCharacters(in: .whitespaces).isEmpty {
                LineHistory.entries.append(str)
                if LineHistory.entries.count > 200 { LineHistory.entries.removeFirst() }
            }
            return str
        case 127, 8:
            if cursor > 0 {
                buffer.remove(at: cursor - 1)
                cursor -= 1
                refresh()
            }
        case 1:
            cursor = 0; refresh()
        case 5:
            cursor = buffer.count; refresh()
        case 2:
            if cursor > 0 { cursor -= 1; refresh() }
        case 6:
            if cursor < buffer.count { cursor += 1; refresh() }
        case 11:
            if cursor < buffer.count {
                buffer.removeSubrange(cursor..<buffer.count)
                refresh()
            }
        case 21:
            buffer.removeAll()
            cursor = 0
            refresh()
        case 23:
            if cursor > 0 {
                var start = cursor
                while start > 0 && buffer[start - 1] == " " { start -= 1 }
                while start > 0 && buffer[start - 1] != " " { start -= 1 }
                buffer.removeSubrange(start..<cursor)
                cursor = start
                refresh()
            }
        case 3:
            _ = write(STDOUT_FILENO, "^C\n", 3)
            FileHandle.standardOutput.write(Data(prompt.utf8))
            buffer.removeAll()
            cursor = 0
            historyIdx = LineHistory.entries.count
            refresh()
            continue
        case 4:
            if buffer.isEmpty {
                _ = write(STDOUT_FILENO, "\n", 1)
                return nil
            } else if cursor < buffer.count {
                buffer.remove(at: cursor)
                refresh()
            }
        case 12:
            _ = write(STDOUT_FILENO, "\u{1B}[2J\u{1B}[H", 7)
            refresh()
        default:
            if byte < 32 { continue }
            var chars: [Character] = []
            if byte < 0x80 {
                chars = [Character(UnicodeScalar(byte))]
            } else {
                let len: Int
                if byte & 0xE0 == 0xC0 { len = 2 }
                else if byte & 0xF0 == 0xE0 { len = 3 }
                else if byte & 0xF8 == 0xF0 { len = 4 }
                else { len = 1 }
                var bytes: [UInt8] = [byte]
                for _ in 1..<len {
                    var nb: UInt8 = 0
                    if read(STDIN_FILENO, &nb, 1) > 0 { bytes.append(nb) }
                }
                if let str = String(bytes: bytes, encoding: .utf8) {
                    chars = Array(str)
                } else { continue }
            }
            if buffer.count + chars.count > 4000 { continue }
            buffer.insert(contentsOf: chars, at: cursor)
            cursor += chars.count
            refresh()
        }
    }
}

// --- TOKEN HELPERS & STATS ---

struct SpecStats {
    var promptTokens = 0
    var verifiedTokens = 0       // draft candidates accepted via batched verification
    var autoregressiveTokens = 0 // tokens generated genuinely (cycle seeds)
    // Positions where a drafted candidate was actually COMPARED and lost. This is
    // the real denominator for acceptance: verified/(verified+divergences).
    var divergences = 0
    // Every candidate in the abandoned tail of a diverged run. Those tokens were
    // batched and decoded, so the work was paid, but only the first one was ever
    // compared -- dividing by this instead produced an "acceptance" number that
    // understated real acceptance by an order of magnitude.
    var rejectedDrafts = 0
    var cycles = 0               // decode cycles (one llama_decode each)
    var naiveCycles = 0          // cycles with no candidates at all
    var serialCycles = 0         // width-1 re-anchor steps
    var runCycles = 0            // trusted-frontier run cycles
    var prefillUs: Int64 = 0
    var prefillCached = 0        // prompt tokens served from the cached prefix KV
    var prefillEvaluated = 0     // prompt tokens actually evaluated this request
    var verifyUs: Int64 = 0      // time in cycle decodes (spec) / gen loop (naive)
    var decodeUs: Int64 = 0      // naive-path generation time
    var events: [String] = []    // per-cycle trace (populated when SPEC_LOG set)
}

private func tokenizeText(_ text: String, addBos: Bool, parseSpecial: Bool) -> [llama_token] {
    let maxTokens: Int32 = 4096
    var tokens = [llama_token](repeating: 0, count: Int(maxTokens))
    let n = text.withCString { cStr in
        llama_tokenize(vocab, cStr, Int32(text.utf8.count), &tokens, maxTokens, addBos, parseSpecial)
    }
    guard n > 0 else { return [] }
    return Array(tokens[0..<Int(n)])
}

private func tokenPiece(_ token: llama_token) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    let n = llama_token_to_piece(vocab, token, &buf, 256, 0, true)
    if n > 0 { return String(cString: buf) }
    return ""
}

// The byte-identical head of every request prompt: the system block, the start
// of the user turn, and (when the request keeps the default control line) the
// control line itself. Derived from buildPromptText so the two cannot drift
// apart, and tokenized on its own so its KV can be evaluated once per process.
private let promptPrefixText: String = {
    let marker = "\u{1}"
    let full = buildPromptText(marker)
    guard let r = full.range(of: marker) else { return "" }
    return String(full[full.startIndex..<r.lowerBound])
}()

private func buildPromptText(_ rawTranscript: String) -> String {
    // Mirror the fixed behavior of the GGUF's embedded chat template.
    let userContent: String
    if rawTranscript.hasPrefix("[Styling:") {
        userContent = rawTranscript
    } else {
        userContent = "\(defaultControl)\n\(rawTranscript)"
    }
    return """
    <|im_start|>system
    You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text.
    <|im_end|>
    <|im_start|>user
    \(userContent)<|im_end|>
    <|im_start|>assistant
    <think>

    </think>

    """
}

private func prefillPrompt(_ tokens: [llama_token], stats: inout SpecStats) -> Bool {
    var batch = llama_batch_init(Int32(tokens.count), 0, 1)
    for (i, tok) in tokens.enumerated() {
        batch.token[i] = tok
        batch.pos[i] = Int32(i)
        batch.n_seq_id[i] = 1
        batch.seq_id[i]![0] = 0
        batch.logits[i] = (i == tokens.count - 1) ? 1 : 0
    }
    batch.n_tokens = Int32(tokens.count)
    let start = ggml_time_us()
    let ok = llama_decode(context, batch) == 0
    llama_synchronize(context)
    stats.prefillUs = ggml_time_us() - start
    llama_batch_free(batch)
    return ok
}

private func makeGreedySampler() -> UnsafeMutablePointer<llama_sampler>? {
    let sparams = llama_sampler_chain_default_params()
    let sampler = llama_sampler_chain_init(sparams)
    llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
    return sampler
}

// --- ASR TEXT NORMALIZATION ---
// The ASR model emits typographic Unicode (curly quotes, en/em dashes, true
// ellipsis, nbsp) while the LLM normalizes these to ASCII in its output.
// Normalizing at entry keeps the speculative draft source byte-identical to
// what the model will generate, eliminating a systematic rejection class
// (every apostrophe-containing word used to force a mismatch + probe churn).
// Explicit map instead of NFKC: predictable, auditable, case untouched.
private func normalizeASRText(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.utf8.count)
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\u{2019}", "\u{2018}": out.append("'")   // ’ ‘  → '
        case "\u{201C}", "\u{201D}": out.append("\"")  // “ ”  → "
        case "\u{2013}", "\u{2014}": out.append("-")   // – —  → -
        case "\u{2026}":             out.append("...") // …    → ...
        case "\u{00A0}":             out.append(" ")   // nbsp → space
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out
}

// --- DRAFT-SOURCE PRE-NORMALIZATION ---
//
// The draft is only a HINT. A wrong guess costs one rejected candidate token
// (~1.3 ms of batched verify) and can never affect correctness, because
// verification is exact greedy and the model's own token always wins. That makes
// it safe to pre-clean the drafting copy toward what the model is likely to emit.
//
// Only the DRAFT is transformed. The prompt still receives the untouched
// transcript, so output is bit-identical across every mode here.
//
// Select with SPEC_DRAFT=raw|filler (default "filler").
//
// This used to offer more: a "soft" mode that also dropped contextual words
// ("like", "so", "well"), and an ITN pass over a dlopen'd FST library, plus
// "+soft"/"+itn" combinators. bench/ measured the contextual list as a wash to a
// net loss, and the ITN pass needed an external dylib that no one else has, so
// all of it is gone -- see the README's Benchmarks section for the numbers.
//
// The surviving "filler" mode does not reproduce its original +5% claim on the
// bench/ corpus either (3.135x vs 3.170x punctuated, 0.935x vs 0.939x raw --
// indistinguishable). Why is visible in the counters: drafts are already accepted
// 95% of the time on punctuated input and 70% on raw input, so there is almost
// nothing left for a draft transform to fix. Run SPEC_CAUSE=1 to see where the
// remaining rejections actually come from before adding another transform.
//
// Both modes remain bit-identical to each other -- only the drafting hint changes.

// Words that are fillers in essentially every context -- safe to drop. A wrong
// drop costs one rejection; a right one buys a longer run.
private let hardFillers: Set<String> = [
    "um", "uh", "uhh", "uhm", "umm", "erm", "er", "hmm", "mmm",
]

/// Drop filler tokens from the draft source, leaving every other byte untouched.
private func stripFillers(_ s: String) -> String {
    var kept: [Substring] = []
    for rawToken in s.split(separator: " ", omittingEmptySubsequences: false) {
        let core = rawToken.trimmingCharacters(in: .punctuationCharacters).lowercased()
        if !hardFillers.contains(core) { kept.append(rawToken) }
    }
    // collapse the runs of spaces a drop leaves behind
    var out = ""
    out.reserveCapacity(s.utf8.count)
    var lastWasSpace = false
    for ch in kept.joined(separator: " ") {
        if ch == " " {
            if lastWasSpace { continue }
            lastWasSpace = true
        } else {
            lastWasSpace = false
        }
        out.append(ch)
    }
    return out.trimmingCharacters(in: .whitespaces)
}

/// Which pre-cleaning the draft source gets. `raw` opts out; anything else --
/// including unset or a typo -- means the default of stripping fillers.
private let draftMode = (ProcessInfo.processInfo.environment["SPEC_DRAFT"] ?? "").lowercased() == "raw"
    ? "raw" : "filler"

/// Build the string the drafting ngram/frontier index is built from.
private func buildDraftSource(_ transcriptText: String) -> String {
    draftMode == "filler" ? stripFillers(transcriptText) : transcriptText
}

// --- STATIC-PROMPT PREFIX REUSE ---
//
// The head of every request prompt is byte-identical, so its KV only ever needs
// computing once per process: warm it at startup, then per request keep the
// longest common token prefix of what is already cached and evaluate just the
// divergent tail -- in ONE pass, requesting logits on the final row only. That
// row's batch index comes back as `firstRow` for the walk's first sample, so
// this also replaces the old two-pass prefill split (body without logits, then
// the last token alone) and saves a full weight read per request.
//
// Nothing here can change the output. KV is only reused for prompt tokens that
// match exactly, everything past the common prefix is truncated out of the cache
// before the tail is evaluated, and the cache is keyed on token ids rather than
// on text, so a tokenizer that splits the boundary differently merely reuses
// less. --verify re-checks all of this against the naive path, which keeps doing
// an independent full prefill on a cleared cache and so never inherits the warm
// prefix. Note the converse: because naive clears the cache, verify runs always
// measure the cold (zero-reuse) spec path.
private var kvPrefixTokens: [llama_token] = []

/// Longest prefix of `tokens` that is already sitting in the cache (seq 0).
private func kvCommonPrefix(_ tokens: [llama_token]) -> Int {
    var l = 0
    let n = min(kvPrefixTokens.count, tokens.count)
    while l < n && kvPrefixTokens[l] == tokens[l] { l += 1 }
    return l
}

/// Evaluate the static prompt head into seq 0, once per process.
private func prefillStaticPrefix() {
    let tokens = tokenizeText(promptPrefixText, addBos: true, parseSpecial: true)
    guard !tokens.isEmpty else { return }
    llama_memory_seq_rm(llama_get_memory(context), 0, -1, -1)
    var b = llama_batch_init(Int32(tokens.count), 0, 1)
    for (i, t) in tokens.enumerated() {
        b.token[i] = t
        b.pos[i] = Int32(i)
        b.n_seq_id[i] = 1
        b.seq_id[i]![0] = 0
        b.logits[i] = 0
    }
    b.n_tokens = Int32(tokens.count)
    let ok = llama_decode(context, b) == 0
    llama_synchronize(context)
    llama_batch_free(b)
    if ok { kvPrefixTokens = tokens }
}

/// Evaluate whatever part of `tokens` is not already cached, leaving exactly one
/// row of logits for the token that follows the prompt. Long tails are chunked to
/// n_batch, which is the same limit the old path respected. `firstRow` reports
/// which row of that final batch holds the logits: the walk samples by BATCH
/// POSITION, and only rows that actually requested logits exist, so this is the
/// batch's last row rather than 0 (the old two-pass split decoded the last prompt
/// token alone purely to make this index 0).
private func prefillPromptTail(_ tokens: [llama_token], stats: inout SpecStats, firstRow: inout Int32) -> Bool {
    var l = kvCommonPrefix(tokens)
    if l >= tokens.count { l = tokens.count - 1 }   // always leave a row to sample
    stats.prefillCached = l

    let start = ggml_time_us()
    defer { stats.prefillUs += ggml_time_us() - start }

    // drop everything past the reusable prefix, including any rejected tail
    llama_memory_seq_rm(llama_get_memory(context), 0, Int32(l), -1)

    let tail = Array(tokens[l...])
    stats.prefillEvaluated = tail.count
    let nBatch = max(1, Int(llama_n_batch(context)))
    var done = 0
    var lastChunk = 0
    while done < tail.count {
        let n = min(nBatch, tail.count - done)
        lastChunk = n
        var b = llama_batch_init(Int32(n), 0, 1)
        for i in 0..<n {
            b.token[i] = tail[done + i]
            b.pos[i] = Int32(l + done + i)
            b.n_seq_id[i] = 1
            b.seq_id[i]![0] = 0
            b.logits[i] = (done + i == tail.count - 1) ? 1 : 0
        }
        b.n_tokens = Int32(n)
        let ok = llama_decode(context, b) == 0
        llama_synchronize(context)
        llama_batch_free(b)
        guard ok else { return false }
        done += n
    }
    firstRow = Int32(lastChunk - 1)
    kvPrefixTokens = tokens
    return true
}

// --- NAIVE PATH (plain greedy autoregressive decoding) ---

func correctNaive(rawTranscript: String, emit: ((String) -> Void)? = nil) -> (output: String, stats: SpecStats) {
    var stats = SpecStats()

    llama_perf_context_reset(context)
    // Deliberately independent of the spec path: clear the cache completely and
    // evaluate the whole prompt, so --verify compares the reused-prefix path
    // against a genuinely separate full prefill. This also drops the warmed
    // prefix, so the spec run that follows measures the cold path.
    llama_memory_seq_rm(llama_get_memory(context), 0, -1, -1)
    kvPrefixTokens = []

    let promptTokens = tokenizeText(buildPromptText(rawTranscript), addBos: true, parseSpecial: true)
    guard !promptTokens.isEmpty else { return ("[Tokenization failed]", stats) }
    stats.promptTokens = promptTokens.count

    guard prefillPrompt(promptTokens, stats: &stats) else {
        return ("[llama_decode failed on prefill]", stats)
    }

    guard let sampler = makeGreedySampler() else { return ("[sampler init failed]", stats) }
    defer { llama_sampler_free(sampler) }

    var nCur = promptTokens.count
    var output = ""
    let genStart = ggml_time_us()

    for _ in 0..<maxTokens {
        let newTokenId = llama_sampler_sample(sampler, context, -1)
        if llama_vocab_is_eog(vocab, newTokenId) { break }
        let piece = tokenPiece(newTokenId)
        output += piece
        emit?(piece)
        stats.autoregressiveTokens += 1

        var nextBatch = llama_batch_init(1, 0, 1)
        nextBatch.token[0] = newTokenId
        nextBatch.pos[0] = Int32(nCur)
        nextBatch.n_seq_id[0] = 1
        nextBatch.seq_id[0]![0] = 0
        nextBatch.logits[0] = 1
        nextBatch.n_tokens = 1

        guard llama_decode(context, nextBatch) == 0 else {
            llama_batch_free(nextBatch)
            break
        }
        llama_batch_free(nextBatch)
        nCur += 1
    }

    llama_synchronize(context)
    stats.decodeUs = ggml_time_us() - genStart
    return (output, stats)
}

// --- SPECULATIVE PATH (lookup-decoding cycle + transcript-frontier drafting) ---
//
// Cycle mechanics are a faithful port of examples/lookup/lookup.cpp:
//   - ONE llama_decode per cycle: batch = [seed @ nPast, candidates...], logits on all.
//   - Verification = sequential sampling walk over output rows; accepted candidates
//     commit in place (nPast++). The first mismatch's sampled token IS greedy's true
//     continuation and becomes the next cycle's seed -- no standalone generation pass.
//   - llama_memory_seq_rm(nPast, -1) wipes the rejected tail; worst case is exactly
//     naive autoregressive speed.
//
// Drafting deviates from upstream's position-blind ngram cache: our corpus is the
// ASR transcript itself and the model copies it front-to-back, so candidates come
// from a tracked frontier `a` (transcript[a...]) and re-anchoring after an edit
// uses trigram/bigram lookups constrained to positions >= the last frontier.
// Position-blind context ngrams proposed mostly-stale matches on edit-heavy input.

func correctSpeculative(rawTranscript: String, emit: ((String) -> Void)? = nil) -> (output: String, stats: SpecStats) {
    var stats = SpecStats()

    // The draft source is the dictated text only (strip a leading control line).
    let transcriptText: String
    if let nl = rawTranscript.firstIndex(of: "\n") {
        transcriptText = String(rawTranscript[rawTranscript.index(after: nl)...])
    } else {
        transcriptText = rawTranscript
    }

    llama_perf_context_reset(context)

    let promptTokens = tokenizeText(buildPromptText(rawTranscript), addBos: true, parseSpecial: true)
    guard !promptTokens.isEmpty else { return ("[Tokenization failed]", stats) }
    stats.promptTokens = promptTokens.count

    // No clear here: prefillPromptTail truncates the cache itself, keeping the
    // static prompt head that is already warm.
    var firstSampleRow: Int32 = 0
    guard prefillPromptTail(promptTokens, stats: &stats, firstRow: &firstSampleRow) else {
        return ("[llama_decode failed on prefill]", stats)
    }

    guard let sampler = makeGreedySampler() else { return ("[sampler init failed]", stats) }
    defer { llama_sampler_free(sampler) }

    let mem = llama_get_memory(context)
    let nDraftMax = max(2, Int(ProcessInfo.processInfo.environment["SPEC_DRAFT_MAX"] ?? "") ?? 64)
    // Bail-out thresholds. Requiring consecutive losing cycles keeps one noisy
    // measurement from abandoning a run that is really ahead, and demanding a 10%
    // margin leaves near-ties (where falling back gains nothing) on the fast path.
    let bailMargin = 1.10
    let bailStreak = 3
    let logging = ProcessInfo.processInfo.environment["SPEC_LOG"] != nil
    let enableJSan = ProcessInfo.processInfo.environment["SPEC_NO_JSAN"] == nil
    let enableBail = ProcessInfo.processInfo.environment["SPEC_NO_BAIL"] == nil
    // Draft length: measured, not guessed. A run of width W costs ~W*m ms of
    // batched verify plus a fixed ~7 ms per cycle, and returns however many
    // tokens the model copied before the first rewrite. On this dictation corpus
    // widening 64 -> 128 costs ~13% (marginal acceptance past 64 falls to 0.229,
    // under the ~0.155 profitability floor) while 32 sits within run-to-run
    // noise of 64. So 64 -- the upstream lookup.cpp default -- is the local
    // optimum; the tiers below only shrink it when the loop is visibly churning.
    func esc(_ t: llama_token) -> String {
        tokenPiece(t).replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
    }

    let transcript = tokenizeText(buildDraftSource(transcriptText), addBos: false, parseSpecial: false)
    let tpc: [[UInt8]] = transcript.map { Array(tokenPiece($0).utf8) }  // pieces for CPU-side resolution
    var tri: [[llama_token]: [Int]] = [:]
    var bi: [[llama_token]: [Int]] = [:]
    if transcript.count >= 3 {
        for i in 2..<transcript.count {
            tri[Array(transcript[(i - 2)...i]), default: []].append(i)  // ends at i
        }
    }
    if transcript.count >= 2 {
        for i in 1..<transcript.count {
            bi[Array(transcript[(i - 1)...i]), default: []].append(i)
        }
    }

    // byte-level view for drift-proof re-anchoring: canonical token IDs can
    // differ between our standalone encoding and the model's greedy generation,
    // so ID-keyed ngram lookups miss; raw bytes never lie.
    var tbytes: [UInt8] = []
    var tstart: [Int] = []         // byte offset where each transcript token starts
    for t in transcript {
        tstart.append(tbytes.count)
        tbytes += Array(tokenPiece(t).utf8)
    }
    tstart.append(tbytes.count)
    var gtail: [UInt8] = []        // rolling tail of generated-output bytes

    var committed = promptTokens   // prompt + generated (mirrors lookup.cpp `inp`)
    var nPast = promptTokens.count
    var usePrefillRow = true       // first sample addresses the prefill's logits row
    var draft: [llama_token] = []  // walk view: candidates only (seed removed post-decode)
    var output = ""
    var hasEos = false

    // alignment state
    var align: Int? = nil          // trusted frontier -> full-width run proposals
    var pendingDiv: Int? = nil     // divergence point awaiting re-anchor
    var bannedBase: Int? = nil     // frontier that failed offset-0 (excluded from locks)
    var givenUp = false
    // Bail-out bookkeeping. A width-1 batch IS one plain autoregressive step, so its
    // measured duration prices the fallback path directly -- no machine- or
    // model-specific constant is needed to decide when speculation stopped paying.
    var naiveUsPerTok = 0.0        // EWMA of a width-1 decode (0 = not measured yet)
    var lastCycleUs: Int64 = 0     // duration of the decode the last walk consumed
    var lastCycleWidth = 0         // width of that decode
    var losingCycles = 0           // consecutive RUN cycles slower than a plain AR token
    var seqRmUs: Int64 = 0         // time spent dropping rejected rows (diagnostic)
    var unproductive = 0
    var confirmedFloor = 0         // conservative floor: only VERIFIED runs advance it;
                                   // wrong locks on repeated phrases can't poison search
    var lockVerified = 0           // tokens verified since current lock acquired
    // Rejection-cause histogram (SPEC_CAUSE=1). Every rejected candidate is
    // classified by comparing the drafted piece against the piece the model chose
    // instead. This is the only thing that can say WHICH draft transform is worth
    // writing: a majority of `case-only`/`boundary-*` means the draft has the
    // right words and only its surface form is wrong, while a majority of
    // `different` means the model is genuinely rewriting and no amount of
    // pre-cleaning the draft will help. Guessing between those two costs weeks.
    let causeLog = ProcessInfo.processInfo.environment["SPEC_CAUSE"] != nil
    var causes: [String: Int] = [:]
    var deadCycles = 0             // cycles that accepted nothing before diverging
    var causeExamples: [String: [String]] = [:]
    var runBase = 0                // transcript origin of the current in-flight run
    var runEff = 0.85              // EWMA of accepted/proposed on run cycles
    var runLen0 = 0                // candidates in flight during the walk

    // --- re-anchor helper (nested to capture state) ---

    @discardableResult
    func tryLock(_ t: llama_token) -> Bool {
        let dbg = ProcessInfo.processInfo.environment["SPEC_DEBUG"] != nil
        // anchored fast-path + SKIP-SCAN: a rewrite ("four thousand" -> "4,000")
        // consumes k draft tokens while producing unrelated model tokens; scan a
        // small window so alignment can jump past the consumed span.
        if let d = pendingDiv {
            var k = 0
            while k <= 6 && d + k < transcript.count {
                if d + k >= confirmedFloor && t == transcript[d + k] {
                    align = d + k + 1
                    pendingDiv = nil
                    lockVerified = 0
                    return true
                }
                k += 1
            }
        }
        // byte-window lock: find generated tail bytes in the transcript, snapped
        // to a token boundary. Immune to ID skew between encodings. Needle length
        // DESCENDS: right after an edit the long tail spans changed text and won't
        // match; a short needle reaches just past the edit where copying resumes.
        let ref = pendingDiv ?? confirmedFloor
        if dbg {
            let hx = gtail.suffix(16).map { String(format: "%02x", $0) }.joined()
            FileHandle.standardError.write(Data("[lock] tail=\(hx) floor=\(confirmedFloor) pendDiv=\(pendingDiv.map(String.init) ?? "-")\n".utf8))
        }
        if gtail.count >= 4 {
            for wlen in stride(from: min(12, gtail.count), through: 4, by: -1) {
                let needle = Array(gtail.suffix(wlen))
                var fronts: [Int] = []
                var i = 0
                while i + wlen <= tbytes.count {
                    if tbytes[i..<(i + wlen)] == needle[0...] {
                        if let ti = tstart.firstIndex(of: i + wlen), ti >= confirmedFloor, ti != bannedBase {
                            fronts.append(ti)
                        }
                    }
                    i += 1
                }
                if dbg { FileHandle.standardError.write(Data("[lock] w=\(wlen) hits=\(fronts.count)\n".utf8)) }
                if let q = fronts.min(by: { abs($0 - ref) < abs($1 - ref) }) {
                    if dbg { FileHandle.standardError.write(Data("[lock] LOCKED q=\(q)\n".utf8)) }
                    align = q
                    pendingDiv = nil
                    lockVerified = 0
                    return true
                }
            }
        }
        // insertion/markup class fallback (list conversion, added punctuation):
        // stale text at the tail's HEAD, new markup at the END. Longest
        // head-prefix present in transcript wins; frontier = end of that head.
        // Requires >=10 bytes of evidence and picks the candidate nearest our
        // best position estimate to avoid locking onto common-word duplicates.
        if gtail.count >= 10 {
            var plen = min(15, gtail.count)
            while plen >= 10 {
                let needle = Array(gtail.prefix(plen))
                var fronts: [Int] = []
                var i = 0
                while i + plen <= tbytes.count {
                    if tbytes[i..<(i + plen)] == needle[0...] {
                        if let ti = tstart.firstIndex(of: i + plen), ti >= confirmedFloor, ti != bannedBase {
                            fronts.append(ti)
                        }
                    }
                    i += 1
                }
                if let q = fronts.min(by: { abs($0 - ref) < abs($1 - ref) }) {
                    if dbg { FileHandle.standardError.write(Data("[lock] PREFIX q=\(q) plen=\(plen)\n".utf8)) }
                    align = q
                    pendingDiv = nil
                    lockVerified = 0
                    return true
                }
                plen -= 1
            }
        }
        // general: recent generated window matched ahead of the confirmed floor
        let genCount = committed.count - promptTokens.count
        if genCount >= 3, let ps = tri[Array(committed.suffix(3))] {
            // nearest to our position estimate: earliest match is usually a
            // stale duplicate in repetitive text
            let fwd = ps.map { $0 + 1 }.filter { $0 >= confirmedFloor && $0 != bannedBase }
            if let q = fwd.min(by: { abs($0 - ref) < abs($1 - ref) }) {
                align = q
                pendingDiv = nil
                lockVerified = 0
                return true
            }
        }
        if genCount >= 2, let ps = bi[Array(committed.suffix(2))] {
            let fwd = ps.map { $0 + 1 }.filter { $0 >= confirmedFloor && $0 != bannedBase }
            if fwd.count == 1, let q = fwd.min(by: { abs($0 - ref) < abs($1 - ref) }) {
                align = q
                pendingDiv = nil
                lockVerified = 0
                return true
            }
        }
        return false
    }

    outer: while !hasEos && stats.verifiedTokens + stats.autoregressiveTokens < maxTokens {
        let v0 = stats.verifiedTokens
        let produced0 = stats.verifiedTokens + stats.autoregressiveTokens
        var iDft = 0
        var divNote: String? = nil
        var lockTried = false
        var lockOK = false
        while true {
            if stats.verifiedTokens + stats.autoregressiveTokens >= maxTokens { break outer }
            // Rows are addressed by batch position and only rows that requested
            // logits exist. The very first sample comes from the prefill batch,
            // whose sole logits row is its last; every cycle batch requests
            // logits on all of its rows, so there the sample row is just iDft.
            let sampleRow = usePrefillRow ? firstSampleRow : Int32(iDft)
            usePrefillRow = false
            let id = llama_sampler_sample(sampler, context, sampleRow)
            if llama_vocab_is_eog(vocab, id) {
                hasEos = true
                break outer
            }
            let idp = tokenPiece(id)
            output += idp
            emit?(idp)
            gtail += Array(idp.utf8)
            if gtail.count > 16 { gtail.removeFirst(gtail.count - 16) }
            committed.append(id)

            if iDft < runLen0 && id == draft[iDft] {
                stats.verifiedTokens += 1
                nPast += 1
                iDft += 1
                if !givenUp && runLen0 > 0 {
                    bannedBase = nil
                    align = runBase + iDft
                    lockVerified += 1
                    if lockVerified >= 12 { confirmedFloor = max(confirmedFloor, align!) }
                }
                continue
            }

            // genuine continuation -> seed of next cycle (not yet in KV)
            stats.autoregressiveTokens += 1
            if runLen0 == 0 && !givenUp {
                lockTried = true
                lockOK = tryLock(id)   // serial step: re-anchor on every new token
            }
            if iDft < runLen0 {
                if causeLog {
                    let cls = classifyRejection(drafted: tokenPiece(draft[iDft]),
                                                actual: tokenPiece(id))
                    causes[cls, default: 0] += 1
                    if iDft == 0 { deadCycles += 1 }
                    if (causeExamples[cls]?.count ?? 0) < 4 {
                        causeExamples[cls, default: []].append(
                            "@\(iDft) exp=\(esc(draft[iDft])) got=\(esc(id))")
                    }
                }
                if logging {
                    divNote = "div@\(iDft) exp='\(esc(draft[iDft]))' got='\(esc(id))'"
                }
                stats.divergences += 1
                stats.rejectedDrafts += runLen0 - iDft
                let div = runBase + iDft
                // CPU-side resolution: replacement TEXT equals a nearby draft
                // token (deletion/filler-drop) or two-token concat (merge)
                // -> resume past it with ZERO serial cycles.
                let rp = Array(tokenPiece(id).utf8)
                var resolved = false
                if enableJSan && !givenUp {
                    var j = 1
                    while j <= 4 && div + j + 1 < transcript.count {
                        if tpc[div + j] == rp {
                            align = div + j + 1
                            resolved = true
                            break
                        }
                        if tpc[div + j] + tpc[div + j + 1] == rp {
                            align = div + j + 2
                            resolved = true
                            break
                        }
                        j += 1
                    }
                    if !resolved {
                        // unresolved: serial disambiguation via tryLock skip-scan
                        pendingDiv = div
                        align = nil
                        lockVerified = 0
                    }
                }
            } else if runLen0 > 0 {
                // clean exhaust: everything proposed was accepted (bonus seeded)
                align = runBase + runLen0
                confirmedFloor = max(confirmedFloor, align!)
                lockVerified = 0
                bannedBase = nil
            }
            break
        }
        if hasEos { break }

        let seqRmT0 = ggml_time_us()
        llama_memory_seq_rm(mem, 0, Int32(nPast), -1)
        seqRmUs += ggml_time_us() - seqRmT0

        // --- productivity guards ---
        stats.cycles += 1
        unproductive = (stats.verifiedTokens - v0 >= 4) ? 0 : unproductive + 1
        // Give up on speculation once it is demonstrably paying less than plain
        // autoregressive decoding. The tokens the walk just produced came from the
        // decode timed as `lastCycleUs`, so cost and yield pair up exactly: divide
        // that decode by this walk's yield and compare against what one AR token
        // costs here. The old trigger needed 24 cycles AND only `accepted < cycles`,
        // which is far weaker than break-even -- on a long context you can be a net
        // loss at 2 accepted per cycle -- so requests running at 0.6x never bailed.
        let cycProduced = stats.verifiedTokens + stats.autoregressiveTokens - produced0
        if !givenUp && enableBail && lastCycleUs > 0 {
            if naiveUsPerTok > 0 {
                // Only RUN cycles get a vote. A width-1 cycle is the fallback itself
                // and sits at parity by construction, so letting it count as a win
                // resets the streak every time the two alternate -- which is exactly
                // the pattern on the low-acceptance requests this exists to catch.
                if lastCycleWidth > 1 {
                    let perTok = Double(lastCycleUs) / Double(max(cycProduced, 1))
                    losingCycles = perTok > naiveUsPerTok * bailMargin ? losingCycles + 1 : 0
                    if losingCycles >= bailStreak { givenUp = true }
                }
            } else if stats.cycles >= 12 && runEff < 0.15 {
                // No width-1 decode has happened yet, so there is nothing to price
                // against (speculation stayed aligned every cycle). Fall back to the
                // acceptance signal: below ~0.13 accepted per produced token a run
                // costs more than the AR steps it replaces, so this is a clear loss.
                givenUp = true
            }
        }
        if givenUp {
            align = nil
            pendingDiv = nil
        }

        // --- proposal phase ---
        let cycAcc = stats.verifiedTokens - v0
        if runLen0 > 0 {
            let eff = Double(cycAcc) / Double(runLen0 + 1)
            runEff = 0.6 * runEff + 0.4 * min(max(eff, 0), 1)
        }
        if logging {
            var ev = "cyc=\(stats.cycles) acc=\(cycAcc)"
            if let d = divNote { ev += " \(d)" }
            if lockTried { ev += " lock=\(lockOK ? "HIT" : "miss")" }
            stats.events.append(ev)
        }
        draft.removeAll(keepingCapacity: true)
        draft.append(committed[committed.count - 1])   // seed heads every batch
        runLen0 = 0

        if let a0 = align, a0 < transcript.count {
            var len = min(nDraftMax - 1, transcript.count - a0)
            if logging { stats.events[stats.events.count - 1] += " -> RUN@\(a0)" }
            // churning region: shrink runs so failed proposals stay cheap;
            // productivity automatically restores full-width runs.
            if unproductive >= 6 || runEff < 0.25 { len = min(len, 12) }
            else if runEff < 0.45 { len = min(len, 32) }
            draft.append(contentsOf: transcript[a0..<(a0 + len)])
            runBase = a0
            runLen0 = len
            stats.runCycles += 1
        } else {
            if ProcessInfo.processInfo.environment["SPEC_DEBUG"] != nil {
                FileHandle.standardError.write(Data("[prop] SERIAL givenUp=\(givenUp)\n".utf8))
            }
            // serial step: decode the seed alone; the walk's tryLock re-anchors
            runBase = 0
            runLen0 = 0
            if givenUp {
                stats.naiveCycles += 1
                if logging { stats.events[stats.events.count - 1] += " -> NAIVE(givenUp)" }
            } else {
                stats.serialCycles += 1
                if logging { stats.events[stats.events.count - 1] += " -> SERIAL" }
            }
        }

        var vb = llama_batch_init(Int32(draft.count), 0, 1)
        for (j, tok) in draft.enumerated() {
            vb.token[j] = tok
            vb.pos[j] = Int32(nPast + j)
            vb.n_seq_id[j] = 1
            vb.seq_id[j]![0] = 0
            vb.logits[j] = 1
        }
        vb.n_tokens = Int32(draft.count)
        let vs = ggml_time_us()
        let rc = llama_decode(context, vb)
        llama_synchronize(context)
        lastCycleUs = ggml_time_us() - vs
        lastCycleWidth = draft.count
        stats.verifyUs += lastCycleUs
        // A width-1 batch is exactly one plain AR step, at this context length and
        // on this machine, so it calibrates the fallback with no assumed constant.
        if draft.count == 1 {
            naiveUsPerTok = naiveUsPerTok == 0
                ? Double(lastCycleUs)
                : 0.7 * naiveUsPerTok + 0.3 * Double(lastCycleUs)
        }
        llama_batch_free(vb)
        guard rc == 0 else { break }
        nPast += 1

        draft.removeFirst()   // walk view: row j carries logits AFTER old draft[j]
    }

    llama_synchronize(context)
    if ProcessInfo.processInfo.environment["SPEC_LOG"] != nil {
        FileHandle.standardError.write(Data(String(format: "[timing] cycles=%d decodes=%.0fms seqRm=%.0fms givenUp=%@\n",
            stats.cycles, Double(stats.verifyUs) / 1000.0, Double(seqRmUs) / 1000.0, givenUp ? "yes" : "no").utf8))
    }
    if causeLog {
        reportRejectionCauses(causes, deadCycles: deadCycles, examples: causeExamples, stats: stats)
    }
    return (output, stats)

}
// --- HIGH-LEVEL ENTRY POINT ---
//
// One full enhancement pass over a single (already length-capped) transcript.
// The CLI one-shot path and the HTTP server both go through here, so identical
// input yields identical output. `emit` receives each finalized piece for
// streaming: speculative verification either commits a sampled token or never
// emits it, so everything emitted is part of the final result.
func enhanceTranscript(_ text: String,
                       naive: Bool,
                       emit: ((String) -> Void)? = nil) -> (output: String, stats: SpecStats) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = normalizeASRText(trimmed)
    return naive
        ? correctNaive(rawTranscript: normalized, emit: emit)
        : correctSpeculative(rawTranscript: normalized, emit: emit)
}

// --- WARM THE STATIC PROMPT PREFIX ---
// A one-time cost, paid here rather than inside every request.
do {
    let t0 = ggml_time_us()
    prefillStaticPrefix()
    if ProcessInfo.processInfo.environment["SPEC_LOG"] != nil {
        let ms = Double(ggml_time_us() - t0) / 1000.0
        FileHandle.standardError.write(Data(String(format: "[prefix] warmed %d tok in %.0fms\n", kvPrefixTokens.count, ms).utf8))
    }
}

/// One-line summary of a decode's counters, shared by the REPL and `--stats` so a
/// benchmark reads exactly what an interactive user sees.
func formatSpecStats(_ s: SpecStats, naive: Bool) -> String {
    // The spec path can serve part of the prompt from the cached prefix, so
    // report prefill throughput over the tokens actually evaluated.
    let prefillEval = s.prefillEvaluated > 0 ? s.prefillEvaluated : s.promptTokens
    let prefillTPS = s.prefillUs > 0 ? Double(prefillEval) / (Double(s.prefillUs) / 1e6) : 0
    var prefillDesc = String(format: "Prefill %.0f t/s (%d tok", prefillTPS, s.promptTokens)
    if s.prefillCached > 0 { prefillDesc += ", \(s.prefillCached) cached" }
    prefillDesc += ")"
    var parts = [prefillDesc]
    if naive {
        let arTPS = s.decodeUs > 0 ? Double(s.autoregressiveTokens) / (Double(s.decodeUs) / 1e6) : 0
        parts.append(String(format: "AR %.0f t/s (%d tok)", arTPS, s.autoregressiveTokens))
    } else {
        // Acceptance over candidates actually COMPARED, not over the whole
        // abandoned tail of every run -- see SpecStats.divergences.
        let compared = s.verifiedTokens + s.divergences
        if s.verifyUs > 0 {
            let vTPS = Double(compared) / (Double(s.verifyUs) / 1e6)
            let accPct = compared > 0 ? 100.0 * Double(s.verifiedTokens) / Double(compared) : 0
            parts.append(String(format: "Draft %.0f tok/s (%d/%d accepted, %.0f%%)",
                                vTPS, s.verifiedTokens, compared, accPct))
        }
        let fromDraftsPct = (s.verifiedTokens + s.autoregressiveTokens) > 0
            ? 100.0 * Double(s.verifiedTokens) / Double(s.verifiedTokens + s.autoregressiveTokens) : 0
        parts.append(String(format: "Gen %.1f%% from drafts (%d serial tok)", fromDraftsPct, s.autoregressiveTokens))
        parts.append(String(format: "Cycles %d (run %d / serial %d / naive %d)", s.cycles, s.runCycles, s.serialCycles, s.naiveCycles))
        if s.rejectedDrafts > 0 { parts.append("Wasted \(s.rejectedDrafts) proposals") }
    }
    return parts.joined(separator: " | ")
}

/// Classify why a drafted candidate was rejected, by comparing the drafted piece
/// with the piece the model emitted instead.
///
/// The buckets are ordered from "the draft was right and only its surface form
/// differed" to "the draft was wrong content":
///
///   same-bytes        identical text, different token id -- pure encoding skew
///   case-or-space     equal ignoring case (whitespace may differ)
///   case-only         equal ignoring case and surrounding whitespace
///   space-only        one side is only whitespace
///   boundary-split    one is a prefix of the other (punctuation/space attached
///                     to a neighbouring token, so the words agree)
///   boundary-contains one contains the other (larger tokenization shift)
///   different         the model emitted genuinely different text
///
/// Everything above `different` is fixable by pre-cleaning the draft source.
/// `different` is not, and if it dominates then draft transforms are the wrong
/// project entirely.
private func classifyRejection(drafted: String, actual: String) -> String {
    if drafted == actual { return "same-bytes" }
    let dl = drafted.lowercased(), al = actual.lowercased()
    if dl == al { return "case-or-space" }
    let dt = dl.trimmingCharacters(in: .whitespacesAndNewlines)
    let at = al.trimmingCharacters(in: .whitespacesAndNewlines)
    if dt.isEmpty || at.isEmpty { return "space-only" }
    if dt == at { return "case-only" }
    if dt.hasPrefix(at) || at.hasPrefix(dt) { return "boundary-split" }
    if dt.contains(at) || at.contains(dt) { return "boundary-contains" }
    return "different"
}

/// Print the SPEC_CAUSE=1 histogram. Percentages are of rejected candidates.
private func reportRejectionCauses(_ causes: [String: Int], deadCycles: Int,
                                   examples: [String: [String]], stats: SpecStats) {
    let total = causes.values.reduce(0, +)
    guard total > 0 else { return }
    var out = "[causes] \(total) rejected candidates across \(stats.cycles) cycles, "
        + "\(stats.verifiedTokens) verified, \(stats.autoregressiveTokens) serial\n"
    if deadCycles > 0 {
        let pct = 100.0 * Double(deadCycles) / Double(stats.cycles)
        out += String(format: "  cycles that accepted nothing before diverging: %d (%.0f%%)\n",
                      deadCycles, pct)
    }
    for (cls, n) in causes.sorted(by: { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }) {
        let pct = 100.0 * Double(n) / Double(total)
        out += "  \(cls.padding(toLength: 24, withPad: " ", startingAt: 0))\(n)  "
            + String(format: "%.1f%%", pct) + "\n"
        for ex in examples[cls] ?? [] { out += "      \(ex)\n" }
    }
    FileHandle.standardError.write(Data(out.utf8))
}

// --- SESSION LOOP ---
if replMode && draftMode != "raw" {
    print("[draft source: \(draftMode)]")
}

// --- SERVER MODE ---
// Never returns: the accept loop owns the process from here. Requests are served
// one at a time because a llama context is not safe to use concurrently.
if httpMode {
    if draftMode != "raw" {
        FileHandle.standardError.write(Data("[draft source: \(draftMode)]\n".utf8))
    }
    runHTTPServer(host: httpHost, port: httpPort, modelName: "s1-mini", naive: naiveMode)
}

// --- ONE-SHOT MODE ---
// Enhance the supplied input and print only the resulting text, then exit.
// Inputs over the single-chunk cap are split at sentence boundaries and stitched.
if let promptInput = promptText {
    if promptInput.utf8.count > Chunker.totalCap {
        FileHandle.standardError.write(Data("Warning: input exceeds \(Chunker.totalCap) characters; truncating the tail.\n".utf8))
    }
    let capped = String(promptInput.prefix(Chunker.totalCap))
    if verifyMode {
        // Dev-only lossless check, usable non-interactively: one chunk, single
        // pass, naive vs speculative compared byte-for-byte. Diagnostics go to
        // stderr so stdout stays pipeable.
        let oneChunk = normalizeASRText(String(capped.prefix(Chunker.singleChunkCap)))
        let naive = correctNaive(rawTranscript: oneChunk)
        let spec = correctSpeculative(rawTranscript: oneChunk)
        let output = (spec.output.isEmpty ? naive.output : spec.output)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        print(output.isEmpty ? "[no output]" : output)
        let verdict = naive.output == spec.output ? "MATCH" : "DIFFER — LOSSLESS CHECK FAILED"
        FileHandle.standardError.write(Data("[verify] lossless: \(verdict)\n".utf8))
    } else {
        let t0 = ggml_time_us()
        let result = enhanceLongText(capped, naive: naiveMode)
        let secs = Double(ggml_time_us() - t0) / 1_000_000.0
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        print(output.isEmpty ? "[no output]" : output)
        if statsMode {
            // stderr keeps stdout a clean pipe of the enhanced text alone.
            let label = naiveMode ? "NAIVE" : "SPEC "
            let line = String(format: "%@ %.2fs | %@", label, secs,
                              formatSpecStats(result.stats, naive: naiveMode))
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }
}

// The session loop only runs when no one-shot prompt was supplied. Letting main
// reach its end (instead of calling exit) keeps the deferred llama cleanup
// running, which the Metal backend requires on teardown.
while replMode {
    guard let line = readLineWithEditing(prompt: "> ") else {
        print("\nExiting.")
        break
    }
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { continue }

    let low = trimmed.lowercased()
    if low == "/quit" || low == "/exit" || low == "/q" {
        print("Exiting.")
        break
    }
    if low == "/help" || low == "/h" || low == "help" {
        print("""
        
        Commands:
          /quit, /exit, /q  — exit session
          /help             — show this help

        Input:
          Type raw transcript and press Enter.
          Default styling: \(defaultControl)
          To use custom styling, start with e.g.:
            [Styling: formal] [Structure: prose] [Context: email]
            please send report asap thanks
          Inputs longer than \(Chunker.singleChunkCap) characters are chunked at
          sentence boundaries and stitched back together automatically.

        Editing:
          Arrow keys, Backspace/Delete, Home/End, Ctrl-A/E/B/F/K/U/W, Ctrl-C to cancel

        """)
        continue
    }

    var toEnhance = trimmed
    if toEnhance.utf8.count > Chunker.totalCap {
        print("[Input exceeds \(Chunker.totalCap) characters; truncating the tail.]")
        toEnhance = String(toEnhance.prefix(Chunker.totalCap))
    }

    print("Enhancing...")
    fflush(stdout)

    var outNaive: String?
    var statsNaive: SpecStats?
    var outSpec: String?
    var statsSpec: SpecStats?
    var naiveSecs = 0.0
    var specSecs = 0.0

    if verifyMode {
        // Dev-only lossless check. Single pass, no chunking, so the naive path's
        // independent full prefill is compared byte-for-byte with the speculative
        // path on identical input. Long inputs are cut to one chunk for this.
        let verifyInput = String(toEnhance.prefix(Chunker.singleChunkCap))
        if verifyInput.count != toEnhance.count {
            print("[verify: input truncated to one \(Chunker.singleChunkCap)-char chunk]")
        }
        let normalized = normalizeASRText(verifyInput)
        var t = ggml_time_us()
        let r1 = correctNaive(rawTranscript: normalized)
        naiveSecs = Double(ggml_time_us() - t) / 1_000_000.0
        (outNaive, statsNaive) = (r1.output, r1.stats)
        t = ggml_time_us()
        let r2 = correctSpeculative(rawTranscript: normalized)
        specSecs = Double(ggml_time_us() - t) / 1_000_000.0
        (outSpec, statsSpec) = (r2.output, r2.stats)
    } else {
        let t = ggml_time_us()
        let r = enhanceLongText(toEnhance, naive: naiveMode)
        let secs = Double(ggml_time_us() - t) / 1_000_000.0
        if naiveMode {
            naiveSecs = secs
            (outNaive, statsNaive) = (r.output, r.stats)
        } else {
            specSecs = secs
            (outSpec, statsSpec) = (r.output, r.stats)
        }
    }

    print()
    print(String(repeating: "-", count: 60))
    let primary = (outSpec ?? outNaive)!.trimmingCharacters(in: .whitespacesAndNewlines)
    print(primary.isEmpty ? "[no output]" : primary)
    print(String(repeating: "-", count: 60))

    if verifyMode {
        // STRICT byte-for-byte comparison. Trimming first would hide a
        // whitespace-only divergence, which is still a divergence: the whole
        // claim being tested is that drafting cannot change the output.
        let nRaw = outNaive!
        let sRaw = outSpec!
        if nRaw == sRaw {
            print("[lossless check: MATCH]")
        } else if nRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                == sRaw.trimmingCharacters(in: .whitespacesAndNewlines) {
            print("[lossless check: WHITESPACE-ONLY DIFF naive=\(nRaw.utf8.count)B spec=\(sRaw.utf8.count)B]")
        } else {
            print("[!!! LOSSLESS CHECK FAILED: outputs differ]")
            print("--- NAIVE OUTPUT ---")
            print(nRaw.isEmpty ? "[no output]" : nRaw)
            print("--- SPEC OUTPUT ---")
            print(sRaw.isEmpty ? "[no output]" : sRaw)
        }
    }

    if let s = statsNaive {
        print(String(format: "NAIVE %.2fs | %@", naiveSecs, formatSpecStats(s, naive: true)))
    }
    if let s = statsSpec {
        print(String(format: "SPEC   %.2fs | %@", specSecs, formatSpecStats(s, naive: false)))
        if verifyMode && naiveSecs > 0 && specSecs > 0 {
            print(String(format: "SPEEDUP: %.2fx", naiveSecs / specSecs))
        }
        if ProcessInfo.processInfo.environment["SPEC_LOG"] != nil {
            for e in s.events { FileHandle.standardError.write(Data("  \(e)\n".utf8)) }
        }
    }
}
