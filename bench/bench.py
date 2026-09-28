#!/usr/bin/env python3
"""Measure draft-source modes against the naive baseline on bench/corpus.jsonl.

What is measured, and why
-------------------------
Prompt-driven speculative decoding never changes the output (that is what
`--verify` is for), so a SPEC_DRAFT transform can only buy *work*: fewer cycles,
fewer wasted proposals, less serial fallback. The engine already reports exactly
those counters via `--stats`, so this harness reads them instead of timing
wall-clock:

  cycles    speculation cycles                     (lower better, exact integer)
  accept    share of COMPARED candidates accepted   (higher better)
  drafts%   share of generated tokens that came from drafts rather than serial
  wasted    candidate tokens batched then abandoned in a diverged run
  secs      the engine's own timed region (excludes model load) -- noisy
  speedup   naive_secs / mode_secs
  recall    share of the reference's words present in the output

`accept` uses the denominator `verified + divergences` (see SpecStats), not
`verified + rejectedDrafts`. The latter counts the whole abandoned tail of every
run, which understated real acceptance by ~10x and made a solved problem look
like an open one.

`recall` is a CONTENT GUARD, not a quality score. The reference was written by a
different model, so perfect agreement is not expected. What recall catches is
content going missing: a sentence dropped at a chunk seam, or -- as this corpus
found on the first run -- the model deleting a whole clause it mistook for a
false start. No speedup is worth losing words.

Modes are interleaved per record so drift within a rep hits every mode equally;
the exact counters are the primary signal and the timings only corroborate.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import statistics
import subprocess
import time
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_BIN = ROOT / ".build/release/s1-mini-engine"
CORPUS = ROOT / "bench/corpus.jsonl"

SPEC_RE = re.compile(r"^(SPEC |NAIVE)\s*([\d.]+)s\s*\|\s*(.+)$", re.M)
CYCLES_RE = re.compile(r"Cycles (\d+) \(run (\d+) / serial (\d+) / naive (\d+)\)")
GEN_RE = re.compile(r"Gen ([\d.]+)% from drafts \((\d+) serial tok\)")
DRAFT_RE = re.compile(r"Draft [\d.]+ tok/s \((\d+)/(\d+) accepted")
WASTED_RE = re.compile(r"Wasted (\d+) proposals")
PREFILL_RE = re.compile(r"Prefill \d+ t/s \((\d+) tok")
AR_RE = re.compile(r"AR \d+ t/s \((\d+) tok\)")
WORD_RE = re.compile(r"[a-z0-9$%]+")


def words(s: str) -> list[str]:
    return WORD_RE.findall(s.lower())


def word_scores(hyp: str, ref: str) -> tuple[float, float, float]:
    """(precision, recall, f1) over word multisets. Order-blind on purpose: it is
    here to catch dropped, duplicated or invented content, nothing subtler."""
    h, r = Counter(words(hyp)), Counter(words(ref))
    if not h or not r:
        return (0.0, 0.0, 0.0)
    overlap = sum((h & r).values())
    p, rec = overlap / sum(h.values()), overlap / sum(r.values())
    f1 = 2 * p * rec / (p + rec) if p + rec else 0.0
    return (p, rec, f1)


def run(binary: pathlib.Path, text: str, mode: str | None, timeout: int) -> dict:
    """One transcript. mode=None is the naive, no-speculation baseline."""
    env = dict(os.environ)
    env.pop("SPEC_LOG", None)
    argv = [str(binary), "--stats", "--prompt", text]
    if mode is None:
        env.pop("SPEC_DRAFT", None)
        argv.insert(1, "--naive")
    else:
        env["SPEC_DRAFT"] = mode

    t0 = time.monotonic()
    proc = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=timeout)
    wall = time.monotonic() - t0
    if proc.returncode != 0:
        raise SystemExit(f"engine failed (mode={mode}, rc={proc.returncode}):\n{proc.stderr[-2000:]}")

    st = {"wall": wall, "out": proc.stdout.strip(), "secs": 0.0, "cycles": 0,
          "ar": 0, "from_drafts": 0.0, "compared": 0, "accepted": 0, "wasted": 0}
    m = SPEC_RE.search(proc.stderr)
    if not m:
        raise SystemExit(f"--stats produced no counters for mode={mode}:\n{proc.stderr[-2000:]}")
    st["secs"] = float(m.group(2))
    body = m.group(3)
    for key, rx in (("cycles", CYCLES_RE), ("prefill", PREFILL_RE), ("ar", AR_RE)):
        hit = rx.search(body)
        if hit:
            st[key] = int(hit.group(1))
    gen = GEN_RE.search(body)
    if gen:
        st["from_drafts"] = float(gen.group(1))
        st["ar"] = int(gen.group(2))
    draft = DRAFT_RE.search(body)
    if draft:
        st["accepted"], st["compared"] = int(draft.group(1)), int(draft.group(2))
    wasted = WASTED_RE.search(body)
    if wasted:
        st["wasted"] = int(wasted.group(1))
    return st


def load_corpus(path: pathlib.Path, regimes: set[str] | None, limit: int | None) -> list[dict]:
    recs = [json.loads(ln) for ln in path.read_text().splitlines() if ln.strip()]
    if regimes:
        recs = [r for r in recs if r["regime"] in regimes]
    return recs[:limit] if limit else recs


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bin", default=str(DEFAULT_BIN))
    ap.add_argument("--corpus", default=str(CORPUS))
    ap.add_argument("--modes", default="raw,filler", help="SPEC_DRAFT values to compare")
    ap.add_argument("--regimes", default="raw,clean")
    ap.add_argument("--reps", type=int, default=1)
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--json", default=None)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    binary = pathlib.Path(args.bin)
    if not binary.exists():
        raise SystemExit(f"binary not found: {binary}\nbuild it with: swift build -c release")

    modes = [m for m in args.modes.split(",") if m]
    regimes = set(args.regimes.split(",")) if args.regimes else None
    corpus = load_corpus(pathlib.Path(args.corpus), regimes, args.limit)
    if not corpus:
        raise SystemExit("corpus is empty; run bench/make_corpus.py")

    plan = ["naive"] + modes          # naive is always the denominator
    runs: list[dict] = []

    for rep in range(args.reps):
        for rec in corpus:
            for mode in plan:
                st = run(binary, rec["input"], None if mode == "naive" else mode, args.timeout)
                st["precision"], st["recall"], st["f1"] = word_scores(st["out"], rec["reference"])
                st.update(id=rec["id"], regime=rec["regime"], mode=mode, rep=rep, chars=rec["chars"])
                runs.append(st)
                if not args.quiet:
                    print(f"  rep{rep} {rec['id']:<16} {mode:<12} {st['secs']:6.2f}s  "
                          f"cyc {st['cycles']:>4}  ar {st['ar']:>4}  "
                          f"rec {st['recall']:.3f}  f1 {st['f1']:.3f}", flush=True)

    def agg(mode: str, regime: str | None) -> dict:
        picked = [r for r in runs if r["mode"] == mode and (regime is None or r["regime"] == regime)]
        if not picked:
            return {}
        return {
            "n": len(picked),
            "secs": sum(r["secs"] for r in picked),
            "cycles": sum(r["cycles"] for r in picked),
            "ar": sum(r["ar"] for r in picked),
            "compared": sum(r["compared"] for r in picked),
            "accepted": sum(r["accepted"] for r in picked),
            "wasted": sum(r["wasted"] for r in picked),
            "from_drafts": statistics.fmean(r["from_drafts"] for r in picked),
            "recall": statistics.fmean(r["recall"] for r in picked),
            "f1": statistics.fmean(r["f1"] for r in picked),
        }

    def table(regime: str | None) -> None:
        base = agg("naive", regime)
        if not base:
            return
        print(f"\n=== {regime or 'ALL'} — {base['n']} runs/mode ===")
        print(f"{'mode':<14}{'secs':>8}{'speedup':>9}{'cycles':>8}{'accept':>8}"
              f"{'drafts%':>9}{'serial':>8}{'wasted':>8}{'recall':>8}{'f1':>7}")
        for mode in plan:
            a = agg(mode, regime)
            if not a:
                continue
            speedup = base["secs"] / a["secs"] if a["secs"] else 0.0
            acc = 100.0 * a["accepted"] / a["compared"] if a["compared"] else float("nan")
            print(f"{mode:<14}{a['secs']:>7.2f}s{speedup:>8.3f}x{a['cycles']:>8}{acc:>7.1f}%"
                  f"{a['from_drafts']:>8.1f}%{a['ar']:>8}{a['wasted']:>8}{a['recall']:>8.3f}{a['f1']:>7.3f}")

    for regime in sorted(regimes or {r["regime"] for r in corpus}):
        table(regime)
    if regimes and len(regimes) > 1:
        table(None)
    print("\naccept  = share of compared candidates accepted (higher is better).")
    print("drafts% = share of generated tokens that came from drafts, not serial steps.")
    print("wasted  = candidates batched then abandoned in a diverged run (lower better).")
    print("recall  = reference words present in the output; drops mean lost content.")
    print("cycles/accept/drafts%/wasted are exact counters; secs/speedup are wall-clock and noisy.")

    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(runs, indent=1))
        print(f"raw runs -> {args.json}")


if __name__ == "__main__":
    main()
