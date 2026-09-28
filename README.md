# s1-mini-engine

A tiny, self-contained Swift **engine for running** the
[Superwhisper S1-mini](https://huggingface.co/superwhisper/s1-mini) model locally
to normalize speech-to-text transcripts. It is the runner, not the model: the
weights come from Hugging Face, and this project is what loads and runs them.

Feed it raw dictation and it returns clean, punctuated, formatted text. No
Python, no separate server, and **no llama.cpp build step**: the whole inference
stack ships as a ~7 MB pre-compiled `llama.xcframework`, so `swift build` links
and produces a working binary in seconds.

```
$ s1-mini-engine "so um we need to talk about the incident that happened last tuesday with our rabbit mq cluster"
So we need to talk about the incident that happened last Tuesday with our RabbitMQ cluster.
```

Requires macOS 14+ on Apple Silicon (the bundled framework is arm64 only).

---

## Install

With Homebrew:

```bash
brew install nub235/tap/s1-mini-engine   # prebuilt binary, no build step
s1-mini-engine pull                      # fetch the Q6_K weights (~495 MB)
```

Or build from source:

```bash
git clone https://github.com/nub235/s1-mini-engine
cd s1-mini-engine
./setup.sh          # downloads the Q6_K model, builds the release binary
```

`setup.sh` builds the release binary (it lands at `.build/release/s1-mini-engine`)
and then fetches the GGUF weights from
[`nub235/s1-mini-GGUF`](https://huggingface.co/nub235/s1-mini-GGUF). The weights
are not committed to the repo (they are ~0.5-1.2 GB); only the ~7 MB framework
and the source are.

You can pick a different quantization:

```bash
MODEL=Q8_0 ./setup.sh   # higher quality, ~640 MB
MODEL=F16  ./setup.sh   # full precision, ~1.2 GB
```

> **Note:** `setup.sh` downloads from `nub235/s1-mini-GGUF` by default. Override
> with `HF_REPO=<user>/<repo>` if you mirror the weights elsewhere.

### If macOS refuses to run it

The binary and the bundled `llama.framework` are **ad-hoc signed, not notarized**
(notarizing needs a paid Apple Developer account), so macOS cannot vouch for them.
Whether that affects you depends only on how the file reached your disk:

| How you got it | Quarantined | Result |
| --- | --- | --- |
| `brew install` | no | runs |
| `curl … \| tar` | no | runs |
| downloaded in a browser, then extracted | **yes** | macOS blocks it |

A quarantined framework fails in a way that is hard to read, because it is the
*dylib* the system objects to, not the command you ran:

```
Library not loaded: @rpath/llama.framework/Versions/Current/llama
  ... (code signature in '.../llama.framework/Versions/A/llama'
       not valid for use in process: library load disallowed by system policy)
```

If you launched it from the Finder you instead get a dialog that waits for a
click, which looks like a hang. Either way, clearing the flag is the whole fix:

```bash
xattr -dr com.apple.quarantine /path/to/s1-mini-engine
xattr -dr com.apple.quarantine /path/to/llama.framework
```

Release tarballs are archived with `--no-xattrs`, so they never ship a quarantine
flag — it is added by whatever downloaded the file, which is why Homebrew and
`curl` never hit this. Note also that `spctl -a` reports `rejected` even for a
working install; that is the notarization check failing, not a broken binary.

### Getting the weights

Downloading the model is always an explicit step, never a side effect of
installing the engine — the binary is small, the weights are not, and a 495 MB
surprise download has no business happening inside an install script. The same
command works whether you built from source or unpacked a release tarball:

```bash
s1-mini-engine pull                       # Q6_K (recommended) → ~/.cache/s1-mini/
s1-mini-engine pull --model Q8_0          # higher quality
s1-mini-engine pull --model F16 --dir .   # full precision, into the current directory
```

Downloads resume if interrupted, and an already-complete file is left alone
(pass `--force` to re-fetch). Files land in `~/.cache/s1-mini/`, which the engine
already searches, so afterwards no model path is needed at all.

`HF_REPO` and `S1_MINI_GGUF_URL` let you pull from a mirror or an exact URL.

---

## Usage

Modes are auto-detected; you rarely need a flag.

```bash
# one-shot: transcript as an argument
s1-mini-engine "um hello there uh i just wanted to say the deploy failed again"

# one-shot: transcript on stdin (handy in pipelines)
echo "um hello there uh the deploy failed again" | s1-mini-engine

# interactive REPL (when stdin is a terminal and no transcript is given)
s1-mini-engine

# OpenAI-compatible HTTP server
s1-mini-engine --http --port 8080

# same, but hold ~60 MB instead of ~1 GB while idle (reloads on demand)
s1-mini-engine --http --port 8080 --idle-timeout 5m

# download the weights (the only subcommand)
s1-mini-engine pull
```

The model path is the first positional argument. It may be omitted when the
GGUF is discoverable, so the commands above "just work" after `./setup.sh`.
Resolution order:

1. an explicit path argument,
2. `$S1_MINI_MODEL`,
3. `./s1-mini-Q6_K.gguf`, `./models/s1-mini-Q6_K.gguf`,
4. `~/.cache/s1-mini/s1-mini-{Q6_K,Q8_0,F16}.gguf` (where `pull` puts them;
   `Q6_K` is preferred when several are present).

If nothing is found, the engine exits with an error rather than guessing —
`pull`, or pass a path.

### Options

`pull` is the one subcommand; it must be the first argument.

| Flag | Meaning |
| --- | --- |
| `pull` | Download the GGUF weights. See [Getting the weights](#getting-the-weights). |
| `-i`, `--repl` | Force the interactive REPL. |
| `--naive` | Plain autoregressive decoding. Use this when the input is raw, unpunctuated ASR output (see below). |
| `--verify` | Dev flag: run naive and speculative decoding and assert byte-identical output. |
| `--stats` | Print decode counters (cycles, acceptance, throughput) to stderr, so stdout stays a clean pipe of the text. |
| `--max-tokens N` | Max generated tokens per request (default `2048`). |
| `--http` | Run the OpenAI-compatible server. |
| `--host H` / `--port N` | Server bind address / port (default `127.0.0.1:8080`). |
| `--idle-timeout D` | Free the model after `D` idle time (`300`, `5m`, `1h`) and reload on the next request. `0` = never unload. See [Memory](#memory-and-idle-unloading). |
| `--prompt "TEXT"` | Alias for passing the transcript positionally. |
| `-h`, `--help`, `--version` | Usage / version. |

### Custom styling

Every request is prefixed with a control line that steers the output. The
default is `[Styling: semi-formal] [Structure: lists] [Context: general]`. Put
your own first line to override it:

```
[Styling: formal] [Structure: prose] [Context: email]
please send the report asap thanks
```

---

## The trick: speculative decoding driven by the prompt

The model's job is to *reformat* text, so most of what it outputs is copied
straight from the input. That is a gift for speculative decoding: the input
itself is used as the draft. Candidate tokens are drawn from the transcript,
verified in a single batched `llama_decode`, and the longest correct prefix is
committed in one step.

On real dictation transcripts this is typically **~2x faster**, and up to
**~3x** on long, well-punctuated transcripts. The output is **byte-identical**
to plain decoding — that guarantee is what `--verify` checks.

Measured on the [`bench/`](bench/) corpus (see [Benchmarks](#benchmarks)):

| input | speedup vs `--naive` | candidates accepted | tokens from drafts |
| --- | --- | --- | --- |
| punctuated (`clean`) | **3.17x** | 95% | 89% |
| raw ASR (`raw`) | **0.94x** | 70% | 29% |

The acceptance numbers are the useful part. The draft is *already* 95% correct
where speculation wins, which means there is very little left for any amount of
pre-cleaning the draft to win — see `SPEC_DRAFT` under
[development flags](#development-flags).

### The one caveat

The speedup depends on the output *resembling the input*. That is true when your
ASR model already emits punctuation, capitalization, and formatting for numbers,
dates, times, and currency, because the normalizer then mostly copies. If you
feed in very raw text with none of that, the drafts mismatch constantly and
speculation can be **slower** than plain decoding. In that case, pass
**`--naive`**.

---

## HTTP API

`--http` serves a minimal OpenAI-compatible surface, so you can point existing
clients at it:

| Method | Path |
| --- | --- |
| `GET` | `/health` |
| `GET` | `/v1/models` |
| `POST` | `/v1/chat/completions` (streaming and non-streaming) |

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "s1-mini",
    "messages": [{"role": "user", "content": "um so uh the deploy failed again"}]
  }'
```

Mapping rules:

- The **last `user` message** is the transcript.
- A `system` message is used as the control line **only if it starts with `[`**
  (the model's `[Styling: ...] [Structure: ...] [Context: ...]` format).
  Ordinary assistant system prompts are ignored so they can't corrupt the
  input.
- `stream: true` returns `text/event-stream` (SSE) with the usual
  `chat.completion.chunk` objects and a terminating `data: [DONE]`.
- **Sampling parameters (`temperature`, `top_p`, `top_k`) are ignored.** The
  engine is exact greedy; honoring them would only break the lossless guarantee.
- `max_tokens` is respected, clamped to the engine budget (2048).
- The advertised model id is `s1-mini` (the model being served); the `model`
  field in requests is not validated.
- Requests are served **one at a time** — a llama context is not safe to use
  concurrently, and this is meant as a single-user local server.

### Long inputs

The model is trained on short inputs, and quality degrades on very long ones.
Inputs longer than **4000 characters** are automatically split at sentence
boundaries, normalized piece by piece, and stitched back together with the
original separators. Requests over **32000 characters** are rejected (`413`);
on the CLI they are truncated with a warning.

---

## Memory and idle unloading

By default the model is loaded at startup and held for the life of the process.
That is roughly **1 GB of RAM** while resident (Q6_K weights plus a 4096-token KV
cache and Metal buffers), which is a lot on an 8 GB machine.

`--idle-timeout` trades a reload for that memory:

```bash
s1-mini-engine --http --port 8080 --idle-timeout 5m
```

The model then loads on **first use** rather than at startup, and is freed after
five minutes with nothing in flight. The next request reloads it — and a reload
means reading the 495 MB file again, about **0.2-0.3 s** while it is still in the
page cache and **~0.75 s** from a cold read. Only `POST` requests load anything;
`GET /health` stays cheap, so a health check never costs you a gigabyte.

Measured with the Q6_K export, reading RSS from `ps`:

| state | RSS |
| --- | --- |
| started with `--idle-timeout`, nothing served yet | **~40 MB** |
| after an idle unload | **~55 MB** |
| one request in flight / recently served | **~1.0 GB** |

An unload therefore returns roughly **0.9 GB**. The two small states are not the
same number: a process that has loaded and released the model holds ~15 MB more
than one that never loaded it. Neither is zero.

Activity Monitor's Memory column reports *physical footprint* rather than RSS and
reads lower again — ~19 MB / ~29 MB / ~527 MB for the same three states — so the
two figures are not in conflict, they are different metrics.

Loads and unloads are announced on stderr, so stdout stays a clean pipe:

```
[model loaded in 0.34s]
[model unloaded after 305s idle]
[model loaded in 0.28s (reload)]
```

Notes:

- `0` (the default) means never unload, which is the original behavior.
- The value is only checked between requests — a long generation will never be
  interrupted by an unload, and a request arriving during one just waits for it.
  [`bench/unload_stress.py`](bench/unload_stress.py) asserts exactly that, because
  the in-flight count has to be per *request* and not per decode: `enhanceLongText`
  loops over chunks, so a count that dropped at every chunk seam would open a
  window for the reaper in the middle of one request.
- Unloads happen on a 1 s poll, so the real idle time is up to a second longer
  than the timeout.
- Do not set it shorter than your typical pause between requests. This flag is
  for reclaiming RAM while you are genuinely away, not for cycling the model
  between keystrokes.

---

## The GGUF exports

The weights this engine runs are a from-scratch export of S1-mini, not the
official files. The official `Q4_K_M` export has some well-known quality
problems — repetition loops and content drift on longer transcripts. The fixes
here (also written up in the
[upstream discussion](https://huggingface.co/superwhisper/s1-mini-GGUF/discussions/1)):

- **Reasoning disabled directly in the chat template**, so you don't have to
  configure it away per call.
- **Context length set to 4096** in the template instead of the broken 1024.
- **De-duplicated tied embeddings.** Qwen3 ties the input embedding and output
  unembedding tensors; the official export stored the same tensor twice.
  Removing the duplicate saves disk and memory, and llama.cpp resolves the tied
  weight for this architecture automatically.
- **Sampling metadata normalized.** The official export bakes in
  `temperature 0.6 / top_p 0.95 / top_k 20`, which forced users to pass
  `--temp 0` manually. These exports bake in greedy decoding instead, so the
  correct behavior is the default.

Shipped quantizations: **`Q6_K`** (recommended, ~495 MB — semantically identical
to full precision, ~100+ tok/s on an M2 MacBook Air), **`Q8_0`** (~640 MB), and
**`F16`** (~1.2 GB). They live at
[`nub235/s1-mini-GGUF`](https://huggingface.co/nub235/s1-mini-GGUF); see
[`hf/`](hf/) for the model card and the upload script.

---

## Building from source

```bash
swift build -c release      # binary at .build/release/s1-mini-engine
swift build                 # debug build
```

The `llama` binary target is the checked-in `llama.xcframework`; there is
nothing else to install.

### Releasing

```bash
./release.sh          # dist/s1-mini-engine-vX.Y.Z-macos-arm64.tar.gz + sha256
./release.sh --tag    # ... and create the matching git tag
```

The version lives in exactly one place, `Sources/s1-mini-engine/Version.swift`,
and `release.sh` reads it, so the tarball, the git tag, and what `--version`
prints cannot drift apart. The tarball is self-contained — it bundles
`llama.framework` next to the binary, because the executable links it from
`@loader_path` — and `release.sh` runs the staged copy before packaging, so a
tarball that ships is a tarball that starts. It never pushes; it prints the
`git push` / `gh release create` commands for you to run deliberately.

It also rewrites the pinned `url` and `sha256` in
[`homebrew/s1-mini-engine.rb`](homebrew/s1-mini-engine.rb), the canonical copy of
the formula served by the [`nub235/homebrew-tap`](https://github.com/nub235/homebrew-tap)
tap, so a release cannot leave the tap pointing at the previous version. Those
substitutions are asserted: reformat the file so the lines no longer match and
the release fails, rather than quietly shipping a stale pin. Publishing the tap
itself stays a deliberate copy-and-push of that one file.

### Development flags

- `--verify` — run naive and speculative decoding on the same input and assert
  byte-identical output; also prints a `[verify] lossless: MATCH` line to
  stderr in one-shot mode.
- `SPEC_DRAFT=raw` — draft from the transcript as-is instead of the pre-cleaned
  copy. Default is `filler`, which drops `um`/`uh`-class words from the drafting
  hint. Either way the output is identical; a previous revision also offered
  `filler+soft` and `filler+itn`, which `bench/` measured as a wash or a net loss
  and which have been removed.
- `SPEC_CAUSE=1` — print a histogram of *why* drafted candidates were rejected,
  classified by comparing the drafted piece against the one the model chose
  (`case-only`, `boundary-split`, `different`, …). Everything except `different`
  is fixable by pre-cleaning the draft; if `different` dominates, no transform
  will help. This exists so draft experiments are measured, not guessed.
- `SPEC_LOG=1` — emit per-cycle speculation traces to stderr.
- `SPEC_NO_BAIL=1`, `SPEC_NO_JSAN=1`, `SPEC_DRAFT_MAX=N` — tuning knobs for the
  speculative engine.

---

## Benchmarks

The draft-hint machinery is only worth tuning against numbers, so `bench/`
measures it. The corpus is built from the
[SottoASR transcript cleanup dataset](https://huggingface.co/datasets/juanquivilla/sotto-transcript-cleanup)
(MIT), whose `input` column is exactly the hard case: lowercase, unpunctuated,
full of disfluencies.

```bash
python3 bench/make_corpus.py                       # rebuild bench/corpus.jsonl
python3 bench/bench.py                             # all 20 records, ~8-10 min
python3 bench/bench.py --limit 4 --modes raw,filler   # fast iteration
```

Individual dataset rows are far too short to benchmark (median 68 characters),
so rows are concatenated into realistic run-on transcripts at 300 / 700 / 1500 /
3000 / **4500** characters — 4500 deliberately past the 4000-character chunk
cap, so the corpus also exercises chunking and stitching. Each record is emitted
twice from the same rows: `raw` (unpunctuated ASR) and `clean` (punctuated), so
the two regimes are directly comparable.

Modes are interleaved per record so drift hits every mode equally, and the
report carries three things worth distinguishing:

- **exact counters** — cycles, acceptance, wasted proposals. These are the
  signal.
- **wall-clock speedup** — noisy; it corroborates, it does not decide.
- **word-level recall against the dataset's reference cleanup** — a *guard*
  rail, not a quality score. The reference was written by a different model, so
  perfect agreement is not expected; what recall catches is content *going
  missing*.

### Reading the acceptance number

`Draft 93 tok/s (34/43 accepted, 79%)` divides accepted candidates by candidates
actually **compared**. An earlier revision divided by `verifiedTokens +
rejectedDrafts`, but that counts the entire abandoned tail of every diverged run
— tokens that were batched and decoded but never compared. It understated real
acceptance by roughly 10x, and made a solved problem look like an open one.

What the numbers say, after that correction:

- **On punctuated input the draft is already right 95% of the time.** Stripping
  fillers (the one transform with a documented win on the older corpus) moves
  nothing measurable here — 3.17x vs 3.14x, well inside run-to-run noise. The
  headroom a draft transform could chase is a couple of percent. That is why the
  `soft` and `itn` draft modes were deleted rather than tuned.
- **The raw regime has a different problem: run length, not accuracy.**
  Acceptance is still 70%, but the model re-punctuates and re-cases every few
  words, so each proposal run dies after ~3 tokens while a cycle costs a fixed
  ~7 ms. 204 cycles for ~180 tokens does not amortize, hence 0.94x. No draft
transform fixes that; the engine's bail-out to plain decoding is the right
response, and `--naive` remains the honest advice for raw input.

---

## Repository layout

```
.
├── Package.swift            # SwiftPM manifest
├── Sources/s1-mini-engine/
│   ├── main.swift           # CLI, model loading, both decode paths
│   ├── Chunker.swift        # sentence-aware chunking + stitching
│   ├── Engine.swift         # model/context lifetime + idle unloading
│   ├── HTTPServer.swift     # OpenAI-compatible HTTP server
│   ├── Puller.swift         # the `pull` subcommand
│   └── Version.swift        # the version, in one place
├── llama.xcframework/       # pre-compiled llama.cpp (arm64 macOS)
│   └── macos-arm64/llama.framework/
├── bench/                   # benchmarks + stress harnesses (dev only, not shipped)
│   ├── make_corpus.py       # builds the corpus from a HF dataset
│   ├── bench.py             # measures draft modes against the engine
│   ├── corpus.jsonl         # the generated corpus (20 transcripts)
│   └── unload_stress.py     # guards --idle-timeout against reaping mid-request
├── hf/                      # publishing the weights to Hugging Face
│   ├── README.md            # the model card
│   └── upload.sh            # uploads the GGUF exports
├── homebrew/
│   └── s1-mini-engine.rb    # canonical formula, mirrored to the tap
├── setup.sh                 # build + `pull`
├── release.sh               # tarball + formula pin (+ optional git tag)
├── .gitignore
└── LICENSE
```

---

## License

MIT for the code (see [LICENSE](LICENSE)). The bundled `llama.xcframework` is a
build of [llama.cpp](https://github.com/ggml-org/llama.cpp), also MIT. The model
weights are distributed under the terms of the upstream
[Superwhisper S1-mini](https://huggingface.co/superwhisper/s1-mini) repository.
