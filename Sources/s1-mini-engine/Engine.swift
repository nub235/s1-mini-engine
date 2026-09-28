import llama
import Foundation

// --- ENGINE: MODEL / CONTEXT LIFETIME ---
//
// The weights (~500 MB of Q6_K) and the context (KV cache at the GGUF's 4096-token
// length, plus Metal compute buffers) live here instead of at file scope so they can
// be handed back to the OS, which is a real amount of RAM on an 8 GB machine.
// Measured on an M-series Mac with the Q6_K export: RSS is ~1.0 GB while loaded and
// drops to ~60 MB after an unload (~42 MB before the first load).
//
// Default (no --idle-timeout): load once at startup, stay resident. Unchanged.
//
// --idle-timeout D: load on first use, then free both after D seconds with no
// request in flight. The next request reloads. The cost of that reload is reading
// the 495 MB file again -- roughly 0.2-0.3s while it is still in the page cache,
// ~0.75s cold. That is the trade being made, deliberately: several hundred MB of
// RAM back, paid for with a stall only after the user has actually been idle.
//
// Threading: exactly one thread ever runs llama work. The main thread does so
// inside correctNaive/correctSpeculative, which bracket themselves with
// beginUse()/endUse(); the reaper thread only frees while `inFlight == 0`, under
// the same lock beginUse() takes. So a free can never overlap a decode. The
// accessors below are deliberately unlocked reads: their correctness comes from
// that bracket, not from a per-access lock.
//
// kvPrefixTokens ("what is resident in seq 0 of the KV cache") lives here too,
// because dropping the context invalidates it, and a stale record would make the
// spec path skip a prefill for tokens that no longer exist.
enum Engine {
    private static let lock = NSLock()

    private static var storedModel: OpaquePointer?
    private static var storedContext: OpaquePointer?

    /// Requests currently decoding. Non-zero pins the model in memory.
    private static var inFlight = 0
    private static var lastUse = Date()
    private static var reaperStop = false

    /// Seconds of inactivity after which the model is freed. 0 = never (default).
    private(set) static var idleTimeout: Double = 0

    /// How many times the model has been (re)loaded. 1 in the default eager mode.
    private(set) static var loadCount = 0

    /// Longest prefix of the last prompt that is known to be in the context's KV
    /// cache (sequence 0). Cleared whenever the context is created or freed.
    static var kvPrefixTokens: [llama_token] = []

    static func configure(idleTimeout seconds: Double) { idleTimeout = seconds }

    // MARK: - Pointer access

    static var currentModel: OpaquePointer {
        guard let m = storedModel else {
            FileHandle.standardError.write(Data("Error: model accessed while unloaded\n".utf8))
            exit(1)
        }
        return m
    }

    static var currentContext: OpaquePointer {
        guard let c = storedContext else {
            FileHandle.standardError.write(Data("Error: context accessed while unloaded\n".utf8))
            exit(1)
        }
        return c
    }

    static var currentVocab: OpaquePointer { llama_model_get_vocab(currentModel) }

    // MARK: - Use bracketing

    /// Pin the engine in memory for one request, loading it first if needed.
    /// Every call must be paired with endUse(); while the count is non-zero the
    /// reaper will not touch the model.
    static func beginUse() {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        inFlight += 1
        lastUse = Date()
    }

    static func endUse() {
        lock.lock()
        inFlight -= 1
        lastUse = Date()
        lock.unlock()
    }

    // MARK: - Loading / unloading

    /// Load the model and context if they are not already resident.
    static func load() {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
    }

    /// Caller must hold `lock`.
    private static func loadLocked() {
        guard storedModel == nil else { return }

        let firstLoad = loadCount == 0
        // The original startup line is only meaningful for the eager load: in lazy
        // mode the first request is the load, and that is announced on stderr.
        let eagerStartup = idleTimeout == 0 && firstLoad

        if eagerStartup && showBanner {
            print("Loading \(modelPath) ...", terminator: "")
            fflush(stdout)
        }

        let t0 = ggml_time_us()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 999 // offload everything to Metal
        guard let m = llama_model_load_from_file(modelPath, mp) else {
            FileHandle.standardError.write(Data("Error: failed to load model at \(modelPath)\n".utf8))
            exit(1)
        }

        var cp = llama_context_default_params()
        cp.n_ctx = 0 // use the context length from GGUF metadata
        cp.n_batch = 1024
        guard let c = llama_init_from_model(m, cp) else {
            FileHandle.standardError.write(Data("Error: failed to create context\n".utf8))
            exit(1)
        }

        storedModel = m
        storedContext = c
        kvPrefixTokens = []
        prefillStaticPrefix() // warm the static prompt head into the fresh KV
        loadCount += 1

        let secs = Double(ggml_time_us() - t0) / 1_000_000.0
        if eagerStartup {
            if showBanner { print(String(format: " %.2fs", secs)) }
        } else {
            let note = firstLoad
                ? String(format: "[model loaded in %.2fs]\n", secs)
                : String(format: "[model loaded in %.2fs (reload)]\n", secs)
            FileHandle.standardError.write(Data(note.utf8))
        }
    }

    /// Caller must hold `lock`, and must have established `inFlight == 0`.
    private static func releaseLocked() {
        guard storedModel != nil || storedContext != nil else { return }
        if let c = storedContext { llama_free(c) }
        if let m = storedModel { llama_model_free(m) }
        storedContext = nil
        storedModel = nil
        kvPrefixTokens = [] // the KV cache went with the context
    }

    // MARK: - Idle reaper

    static func startReaper() {
        guard idleTimeout > 0 else { return }
        let t = Thread {
            // 1 s granularity: an uncontended wake-up costs nothing next to a
            // request, and the unload only needs to be roughly on time.
            while true {
                Thread.sleep(forTimeInterval: 1.0)
                lock.lock()
                let stop = reaperStop
                lock.unlock()
                if stop { return }
                reapIfIdle()
            }
        }
        t.name = "s1-mini-idle-reaper"
        t.start()
    }

    private static func reapIfIdle() {
        lock.lock()
        defer { lock.unlock() }
        guard idleTimeout > 0, inFlight == 0, storedModel != nil else { return }
        let idle = Date().timeIntervalSince(lastUse)
        guard idle >= idleTimeout else { return }
        releaseLocked()
        FileHandle.standardError.write(Data(String(format: "[model unloaded after %.0fs idle]\n", idle).utf8))
    }

    /// Stop the reaper and free whatever is still resident, so teardown happens in
    /// a defined order on normal exit (see the matching defer in main.swift).
    static func shutdown() {
        lock.lock()
        reaperStop = true
        releaseLocked()
        lock.unlock()
    }
}

// The bare names the decode path has always used. Computed, so they follow the
// current model across an idle unload and reload. Valid only while a decode is in
// flight (between Engine.beginUse() and Engine.endUse()).
var model: OpaquePointer { Engine.currentModel }
var context: OpaquePointer { Engine.currentContext }
var vocab: OpaquePointer { Engine.currentVocab }
