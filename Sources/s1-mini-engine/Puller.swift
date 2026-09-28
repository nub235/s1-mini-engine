import Foundation

// --- `pull`: fetch the model weights -----------------------------------------
//
// This is deliberately the *only* thing in the project that downloads weights:
//
//   * installers (Homebrew formulas, tarballs) stay small and side-effect free —
//     no 495 MB surprise download during `brew install`;
//   * cloning the source no longer implies pulling the model;
//   * and it works standalone, with no setup.sh and no git checkout.
//
// The download itself is delegated to `curl`, which is present on every macOS
// install, resumes partial files (`-C -`), follows the Hugging Face redirect to
// the CDN, and prints a progress bar. Re-implementing range-resume against
// URLSession would be more code and more ways to corrupt a 495 MB file.

/// Supported exports, in the order the model search should prefer them (Q6_K is
/// the recommended one). Shared with `resolveModelPath` in main.swift.
let pullChoices = ["Q6_K", "Q8_0", "F16"]
private let pullDefaultRepo = "nub235/s1-mini-GGUF"

private func pullFail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    exit(1)
}

private func printPullUsage() {
    print("""
    \(programName) pull — download the S1-mini GGUF weights

    USAGE:
      \(programName) pull [--model Q6_K|Q8_0|F16] [--dir PATH] [--force]

    OPTIONS:
      --model NAME   quantization to fetch (default Q6_K, recommended)
                     Q6_K ~495 MB, Q8_0 ~640 MB, F16 ~1.2 GB
      --dir PATH     destination directory (default ~/.cache/s1-mini)
      --force        re-download even if the file already looks complete
      -h, --help     show this help

    ENVIRONMENT:
      MODEL             default for --model
      HF_REPO           Hugging Face repo to pull from (default \(pullDefaultRepo))
      S1_MINI_GGUF_URL  exact URL to download instead of HF_REPO

    Files land in a directory \(programName) already searches, so after a pull
    you can run \(programName) "..." with no model path at all. Downloads resume
    if they were interrupted.
    """)
}

/// Human-readable byte size, e.g. "495.2 MB".
private func formatBytes(_ count: Int) -> String {
    String(format: "%.1f %@", count >= 1_000_000_000
        ? Double(count) / 1_000_000_000 : Double(count) / 1_000_000,
        count >= 1_000_000_000 ? "GB" : "MB")
}

/// `s1-mini-engine pull ...`. Handled before the main argument parser (which
/// would otherwise treat the word "pull" as the transcript) and before any model
/// loading, so it never requires a working GGUF to exist.
func runPull(_ args: [String]) -> Never {
    let env = ProcessInfo.processInfo.environment
    var model = env["MODEL"] ?? "Q6_K"
    var dir = (NSHomeDirectory() as NSString).appendingPathComponent(".cache/s1-mini")
    var force = false

    var i = 0
    while i < args.count {
        let arg = args[i]
        func value(_ flag: String) -> String {
            i += 1
            guard i < args.count else { pullFail("\(flag) requires a value") }
            return args[i]
        }
        switch arg {
        case "-h", "--help": printPullUsage(); exit(0)
        case "--model": model = value("--model")
        case "--dir": dir = value("--dir")
        case "--force": force = true
        default: pullFail("unknown option for pull: \(arg) (try `\(programName) pull --help`)")
        }
        i += 1
    }

    guard pullChoices.contains(model) else {
        pullFail("--model must be one of \(pullChoices.joined(separator: ", ")) (got '\(model)')")
    }

    let filename = "s1-mini-\(model).gguf"
    let fm = FileManager.default

    do {
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    } catch {
        pullFail("could not create \(dir): \(error.localizedDescription)")
    }

    let destination = (dir as NSString).appendingPathComponent(filename)
    // Downloads land on `…gguf.part` and are renamed only once verified, so the
    // presence of the final name is proof of a complete file and the presence of
    // the `.part` name is proof of a resumable one. Without that split, a run
    // interrupted halfway would leave a truncated GGUF that looks installed.
    let partial = destination + ".part"

    if fm.fileExists(atPath: destination), !force {
        let size = fileSize(destination)
        print("\(filename) is already present (\(formatBytes(size)))")
        print("  \(destination)")
        if fm.fileExists(atPath: partial) {
            try? fm.removeItem(atPath: partial)  // stale remnant of a past run
        }
        print("Pass --force to download it again.")
        print("\n" + pullNextSteps(model: model, path: destination))
        exit(0)
    }

    if force {
        // Start over rather than resume: `curl -C -` against an already-complete
        // file asks for a range past the end and the server answers 416.
        try? fm.removeItem(atPath: destination)
        try? fm.removeItem(atPath: partial)
    }

    let url = env["S1_MINI_GGUF_URL"]
        ?? "https://huggingface.co/\(env["HF_REPO"] ?? pullDefaultRepo)/resolve/main/\(filename)"

    let curlPath = ["/usr/bin/curl", "/usr/local/bin/curl", "/opt/homebrew/bin/curl"]
        .first { fm.isExecutableFile(atPath: $0) } ?? "/usr/bin/curl"
    guard fm.isExecutableFile(atPath: curlPath) else {
        pullFail("curl is required to download weights but was not found.\n"
            + "Download manually and place it at \(destination):\n  \(url)")
    }

    let alreadyHave = fileSize(partial)
    if alreadyHave > 0 {
        print("Resuming an interrupted download \(formatBytes(alreadyHave)) in")
    }
    print("Downloading \(filename) → \(destination)")
    print("  from \(url)\n")

    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: curlPath)
    curl.arguments = ["-L", "--fail", "--progress-bar", "-C", "-", "-o", partial, url]
    do {
        try curl.run()
    } catch {
        pullFail("could not run curl: \(error.localizedDescription)")
    }
    curl.waitUntilExit()

    guard curl.terminationStatus == 0 else {
        let kept = fileSize(partial)
        var message = "download failed (curl exited \(curl.terminationStatus))."
        if kept > 0 {
            message += "\nThe partial download was kept at \(partial); re-run to resume it."
        } else {
            // Nothing to resume, so the cause is upstream. 401/403 here almost
            // always means the model repository is private or does not exist.
            try? fm.removeItem(atPath: partial)
            message += "\nNothing was downloaded. Check that the model repository "
                + "is public and that the file name is right:\n  \(url)"
        }
        pullFail(message)
    }

    let size = fileSize(partial)
    guard size > 0 else {
        try? fm.removeItem(atPath: partial)
        pullFail("downloaded file was empty; nothing to run. Check the URL:\n  \(url)")
    }

    // HF serves an HTML page for some failures with a 200 status, and curl only
    // reports transport-level errors. Every GGUF starts with the magic "GGUF", so
    // a cheap header read catches a surprising payload before it is installed.
    guard startsWithGGUF(partial) else {
        try? fm.removeItem(atPath: partial)
        pullFail("the download was not a GGUF file (bad magic bytes) — nothing installed.\n"
            + "Check that the repo and file name are right:\n  \(url)")
    }

    try? fm.removeItem(atPath: destination)
    do {
        try fm.moveItem(atPath: partial, toPath: destination)
    } catch {
        pullFail("downloaded successfully but could not be moved into place: "
            + "\(error.localizedDescription)\nThe file is at \(partial).")
    }

    print("\nFetched \(filename) (\(formatBytes(size)))")
    print("  \(destination)")
    print("\n" + pullNextSteps(model: model, path: destination))
    exit(0)
}

/// Size of a file in bytes, or 0 if it is missing or unreadable.
private func fileSize(_ path: String) -> Int {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return 0 }
    return (attrs[.size] as? NSNumber)?.intValue ?? 0
}

/// Whether a file begins with the GGUF magic number, i.e. is plausibly a model
/// and not an error page that happened to come back with a 200.
private func startsWithGGUF(_ path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? handle.close() }
    return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
}

/// Closing hint showing how to invoke the engine now that weights are local.
private func pullNextSteps(model: String, path: String) -> String {
    var lines = ["Run it:"]
    lines.append("  \(programName) \"um so uh the deploy failed again\"")
    if model != "Q6_K" {
        // The cache is searched automatically, but Q6_K wins when several exports
        // are present because it comes first in the search order.
        lines.append("")
        lines.append("\(model) works with no configuration unless you also have Q6_K")
        lines.append("in the same directory; Q6_K is preferred. To force \(model):")
        lines.append("  export S1_MINI_MODEL=\(path)")
    }
    return lines.joined(separator: "\n")
}
