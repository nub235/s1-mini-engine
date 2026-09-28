#!/usr/bin/env python3
"""Build the draft-quality benchmark corpus from the SottoASR cleanup dataset.

Source: https://huggingface.co/datasets/juanquivilla/sotto-transcript-cleanup
        (already in the local HF cache; run `huggingface-cli download` first)

The dataset is 135K+ (raw ASR transcript -> clean text) pairs. Its `input` column
is exactly the hard case for prompt-driven speculative decoding: lowercase,
unpunctuated, full of disfluencies, so almost nothing in the draft index survives
into the model's output.

Individual rows are far too short to benchmark (median 68 chars) -- at that size
the fixed per-cycle cost dominates and the result says nothing about long
dictation. So rows are concatenated into realistic run-on transcripts at the
lengths this engine actually sees. Each record is emitted twice, from the same
underlying rows:

  raw    unpunctuated disfluent ASR text  -> the regime where speculation is
                                             supposed to struggle
  clean  punctuated capitalized text      -> the regime the headline speedup
                                             is measured in

Both variants share the same source rows, so the two regimes are comparable.

`output` is the dataset's reference cleanup. It is NOT what S1-mini would emit
(different model), but it is a good enough proxy to check word-level content
preservation -- which is what catches chunking/stitching bugs at >4000 chars.

Deterministic: same seed, same corpus.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import random
import re

HF_CACHE = (
    pathlib.Path.home()
    / ".cache/huggingface/hub/datasets--juanquivilla--sotto-transcript-cleanup"
)


def find_parquet() -> pathlib.Path:
    """Locate the dataset in the HF cache without hard-coding a snapshot hash.

    Snapshot directory names are commit hashes that change whenever the dataset
    is revised, so glob for them. The validation split is preferred: it is big
    enough (6,921 rows) and keeps the corpus stable if `train` is re-uploaded.
    """
    found = sorted(HF_CACHE.glob("snapshots/*/data/*.parquet"))
    if not found:
        raise SystemExit(
            f"dataset not found in the HF cache ({HF_CACHE})\n"
            "fetch it with:\n  huggingface-cli download "
            "juanquivilla/sotto-transcript-cleanup --repo-type dataset"
        )
    for pref in ("validation", "train", "test"):
        for path in found:
            if path.name.startswith(pref):
                return path
    return found[0]

# 4500 deliberately exceeds the engine's 4000-char single-chunk cap so the corpus
# exercises sentence-boundary chunking and stitching, not just single-pass runs.
TARGET_LENGTHS = [300, 700, 1500, 3000, 4500]
PER_LENGTH = 2
SEED = 20260927

# Only plain, well-formed rows: no stray newlines or markup, no rows so long they
# would dominate a concatenation on their own.
ROW_MAX_CHARS = 160
IN_RE = re.compile(r"^[a-z0-9][a-z0-9 ,.'?!%$/-]*[a-z0-9.?!]$")


def load_rows(limit: int) -> list[dict]:
    import pyarrow.parquet as pq

    rows = pq.read_table(find_parquet(), columns=["input", "output"]).to_pylist()
    keep = []
    for r in rows[:limit]:
        i, o = (r.get("input") or "").strip(), (r.get("output") or "").strip()
        if not i or not o or len(i) > ROW_MAX_CHARS:
            continue
        if "\n" in i or "\n" in o:
            continue
        if not IN_RE.match(i):
            continue
        keep.append({"input": i, "output": o})
    return keep


def build(rows: list[dict], rng: random.Random) -> list[dict]:
    out = []
    for target in TARGET_LENGTHS:
        for rep in range(PER_LENGTH):
            src, raw, clean = [], [], []
            chars = 0
            # Walk randomly through the row pool, accumulating whole rows until the
            # target length is reached. Rows are consumed with replacement, so this
            # terminates for any target.
            while chars < target:
                row = rows[rng.randrange(len(rows))]
                src.append(row)
                raw.append(row["input"])
                clean.append(row["output"])
                chars += len(row["input"]) + 1
            out.append(
                {
                    "id": f"raw-{target}-{rep}",
                    "regime": "raw",
                    "rows": len(src),
                    "chars": len(" ".join(raw)),
                    "input": " ".join(raw),
                    "reference": " ".join(clean),
                }
            )
            out.append(
                {
                    "id": f"clean-{target}-{rep}",
                    "regime": "clean",
                    "rows": len(src),
                    "chars": len(" ".join(clean)),
                    "input": " ".join(clean),
                    "reference": " ".join(clean),
                }
            )
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default="bench/corpus.jsonl")
    ap.add_argument("--scan", type=int, default=4000, help="rows of the parquet to consider")
    ap.add_argument("--seed", type=int, default=SEED)
    args = ap.parse_args()

    print(f"source: {find_parquet()}")
    rows = load_rows(args.scan)
    if len(rows) < 200:
        raise SystemExit(f"only {len(rows)} usable rows found; dataset missing or filtered too hard")

    corpus = build(rows, random.Random(args.seed))

    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w") as fh:
        for rec in corpus:
            fh.write(json.dumps(rec) + "\n")

    print(f"wrote {out} ({len(corpus)} records) from {len(rows)} usable rows")
    for rec in corpus:
        print(f"  {rec['id']:<18} {rec['chars']:>5} chars  {rec['rows']:>3} rows")


if __name__ == "__main__":
    main()
