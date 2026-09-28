---
base_model: superwhisper/s1-mini
library_name: llama.cpp
pipeline_tag: text-generation
tags:
  - gguf
  - llama.cpp
  - qwen3
  - speech-to-text
  - transcript
  - text-normalization
---

# S1-mini GGUF (fixed export)

GGUF quantizations of [Superwhisper S1-mini](https://huggingface.co/superwhisper/s1-mini),
a small model that cleans up and formats speech-to-text transcripts: it adds
punctuation and capitalization, fixes disfluencies, and formats numbers, dates,
times, and currency.

This is an independent, from-scratch export — not the official GGUF. It fixes
several issues in the official files (see
[the upstream discussion](https://huggingface.co/superwhisper/s1-mini-GGUF/discussions/1)).

## Files

| File | Size | Notes |
| --- | --- | --- |
| [`s1-mini-Q6_K.gguf`](./s1-mini-Q6_K.gguf) | ~495 MB | **Recommended.** Semantically identical to full precision, ~100+ tok/s on an M2 MacBook Air. |
| [`s1-mini-Q8_0.gguf`](./s1-mini-Q8_0.gguf) | ~640 MB | Near-lossless; a little more headroom if you have the RAM. |
| [`s1-mini-F16.gguf`](./s1-mini-F16.gguf) | ~1.2 GB | Full-precision reference. |

`Q6_K` is the default. The official `Q4_K_M` export has known quality problems —
repetition loops and content drift on longer transcripts — so these exports
deliberately skip that quantization level.

## What was fixed relative to the official export

- **Reasoning disabled in the chat template.** No per-call configuration needed.
- **Context length corrected to 4096** in the template (the official export
  shipped a broken 1024).
- **Tied embeddings de-duplicated.** Qwen3 ties the input embedding and output
  unembedding tensors; the official export stored the same tensor twice. This
  export removes the duplicate, saving disk and memory — llama.cpp resolves the
  tied weight for this architecture automatically.
- **Sampling metadata normalized.** The official export bakes in
  `temperature 0.6 / top_p 0.95 / top_k 20`, which forced users to pass
  `--temp 0` by hand. Here greedy decoding is the baked-in default, so the
  correct behavior is what you get out of the box.

## Usage

### With llama.cpp

```bash
llama-cli -m s1-mini-Q6_K.gguf \
  -p '[Styling: semi-formal] [Structure: lists] [Context: general]
um so we need to talk about the incident that happened last tuesday with our rabbit mq cluster'
```

### With the `s1-mini-engine` runner (fast path)

<https://github.com/nub235/s1-mini-engine> is a small Swift CLI and
OpenAI-compatible local server built around these exports. It adds
prompt-driven speculative decoding — it drafts candidate tokens from the input
transcript and verifies them in one batched decode — for roughly **2x-3x**
speedup over plain decoding, with byte-identical output.

```bash
./setup.sh                  # downloads Q6_K and builds the binary
s1-mini-engine "um so uh the deploy failed again"
s1-mini-engine --http       # OpenAI-compatible server on 127.0.0.1:8080
```

## Prompt format

Input is a single user turn prefixed with a control line:

```
[Styling: <tone>] [Structure: <shape>] [Context: <domain>]
<raw transcript>
```

For example: `[Styling: formal] [Structure: prose] [Context: email]`.

## License

The weights derive from `superwhisper/s1-mini`; see that repository for the
applicable license terms. The export tooling in the linked project is MIT.
