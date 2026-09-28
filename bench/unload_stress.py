#!/usr/bin/env python3
"""Regression test for the --idle-timeout reaper: the model must never be freed
while a request is still in flight.

Why this exists
---------------
The reaper only frees the model when the in-flight count is zero, so the whole
safety property is the correctness of that count. The bracket used to wrap each
decode rather than each request, and `enhanceLongText` loops over chunks -- so a
multi-chunk request dropped the count to zero at every chunk SEAM, leaving a
window in which the reaper could free the model out from under the loop. Every
single-chunk request passed; only a multi-chunk one could expose it.

So this drives exactly that shape: inputs past the 4000-char chunk cap, plus
overlapping requests, and asserts that no `[model unloaded ...]` and no
`[model loaded ...]` line appears between a request's start and its completion.

The assertion is a line timeline, not a memory gauge: brackets are exact events,
whereas RSS is fuzzy and platform-dependent. RSS is still measured and reported,
because the point of the feature is the ~940 MB it gives back.

This is not a vacuous test. Phase E asserts that an unload DOES happen once the
server is genuinely idle, so a run that never unloads at all -- and therefore
could never trip the mid-request assertion -- fails rather than passes quietly.

Usage:
    swift build -c release
    bench/unload_stress.py                  # reaper at 2s, the tightest useful value
    bench/unload_stress.py --idle-timeout 5 --chars 6000

The weights are found through the engine's own search (including
~/.cache/s1-mini/), so --model is only needed for a non-default GGUF.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_BIN = ROOT / ".build/release/s1-mini-engine"
CORPUS = ROOT / "bench/corpus.jsonl"

LOAD_RE = re.compile(r"\[model loaded in [\d.]+s(?: \(reload\))?\]")
UNLOAD_RE = re.compile(r"\[model unloaded after (\d+)s idle\]")

# The reaper ticks every second, so an unload lands up to ~1s late; leave room.
REAPER_SLACK = 4.0


class Server:
    """`--http` under test, with its output timestamped as it arrives.

    Both streams are pumped so the process can never block on a full pipe. Only
    stderr carries the brackets, but stdout is drained too.
    """

    def __init__(self, argv: list[str], port: int):
        self.port = port
        self.lines: list[tuple[float, str]] = []
        self._lock = threading.Lock()
        self.proc = subprocess.Popen(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True,
        )
        for stream in (self.proc.stdout, self.proc.stderr):
            threading.Thread(target=self._pump, args=(stream,), daemon=True).start()

    def _pump(self, stream) -> None:
        for line in stream:
            with self._lock:
                self.lines.append((time.monotonic(), line.rstrip("\n")))

    def window(self, t0: float, t1: float) -> list[tuple[float, str]]:
        with self._lock:
            return [(t, ln) for t, ln in self.lines if t0 <= t <= t1]

    def strip(self) -> str:
        with self._lock:
            return "\n".join(ln for _, ln in self.lines)

    def rss_mb(self) -> float:
        out = subprocess.run(
            ["ps", "-o", "rss=", "-p", str(self.proc.pid)],
            capture_output=True, text=True,
        ).stdout.strip()
        return int(out) / 1024 if out else float("nan")

    def stop(self) -> None:
        self.proc.terminate()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def wait_healthy(port: int, timeout: float = 60.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as r:
                if r.status == 200:
                    return True
        except (urllib.error.URLError, OSError):
            time.sleep(0.2)
    return False


def chat(base: str, text: str, timeout: float) -> str:
    payload = json.dumps(
        {"model": "s1-mini", "messages": [{"role": "user", "content": text}]}
    ).encode()
    req = urllib.request.Request(
        f"{base}/v1/chat/completions", data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = json.loads(resp.read().decode())
    choice = body["choices"][0]
    return choice.get("message", {}).get("content") or choice.get("text", "")


def long_input(min_chars: int) -> str:
    """The longest corpus transcript, extended until it is past the chunk cap.

    Taken from bench/corpus.jsonl so the shape is the one the benchmark measures
    rather than something invented here.
    """
    text = ""
    if CORPUS.exists():
        recs = [json.loads(ln) for ln in CORPUS.read_text().splitlines() if ln.strip()]
        recs.sort(key=lambda r: r["chars"])
        if recs:
            text = recs[-1]["input"]
            for rec in reversed(recs):          # pad from other transcripts if needed
                if len(text) >= min_chars:
                    break
                text = f"{text} {rec['input']}"
    while len(text) < min_chars:
        text = f"{text} the deploy failed again and we should talk about the incident"
    return text


def check(checks: list[tuple[bool, str, str]], ok: bool, label: str, detail: str = "") -> None:
    """Record a result and stream it, so a slow run shows where it got to."""
    checks.append((ok, label, detail))
    print(f"  {'ok  ' if ok else 'FAIL'}  {label:<46}{detail}", flush=True)


def report(checks: list[tuple[bool, str, str]]) -> int:
    failed = [c for c in checks if not c[0]]
    print(f"\n{len(checks) - len(failed)}/{len(checks)} checks passed", flush=True)
    for _, label, detail in failed:
        print(f"  FAIL  {label}  {detail}")
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--bin", default=str(DEFAULT_BIN))
    ap.add_argument("--model", default=None, help="GGUF path; default = let the engine search")
    ap.add_argument("--port", type=int, default=8123)
    ap.add_argument("--idle-timeout", type=float, default=2.0)
    ap.add_argument("--chars", type=int, default=4200, help="length of the chunked input")
    ap.add_argument("--timeout", type=float, default=900.0, help="per-request timeout")
    args = ap.parse_args()

    binary = pathlib.Path(args.bin)
    if not binary.exists():
        raise SystemExit(f"binary not found: {binary}\nbuild it with: swift build -c release")

    argv = [str(binary), "--http", "--port", str(args.port),
            "--idle-timeout", str(args.idle_timeout)]
    if args.model:
        argv.append(args.model)

    base = f"http://127.0.0.1:{args.port}"
    text = long_input(args.chars)
    print(f"engine      {binary}")
    print(f"idle        {args.idle_timeout:g}s")
    print(f"chunked in  {len(text)} chars (cap is 4000, so this takes >1 chunk)")
    print(f"port        {args.port}\n")

    srv = Server(argv, args.port)
    checks: list[tuple[bool, str, str]] = []
    try:
        if not wait_healthy(args.port):
            print(srv.strip())
            raise SystemExit("server never became healthy")

        # --- A: with --idle-timeout the model must NOT load at startup ----------
        time.sleep(0.5)
        rss_cold = srv.rss_mb()
        startup_loads = [ln for _, ln in srv.window(0.0, time.monotonic()) if LOAD_RE.search(ln)]
        check(checks, not startup_loads, "no model loaded at startup (lazy)",
              f"rss {rss_cold:.0f} MB")

        # --- B: first request loads it -----------------------------------------
        t0 = time.monotonic()
        chat(base, "um hello there uh the deploy failed again", args.timeout)
        t1 = time.monotonic()
        loaded_here = [ln for _, ln in srv.window(t0, t1) if LOAD_RE.search(ln)]
        rss_loaded = srv.rss_mb()
        check(checks, bool(loaded_here), "first request loads the model",
              f"{loaded_here[0] if loaded_here else 'no bracket'}  ({t1 - t0:.1f}s)")

        # --- C: the regression -- one multi-chunk request ----------------------
        t0 = time.monotonic()
        out = chat(base, text, args.timeout)
        t1 = time.monotonic()
        mid = [(t, ln) for t, ln in srv.window(t0, t1)
               if LOAD_RE.search(ln) or UNLOAD_RE.search(ln)]
        dur = t1 - t0
        check(checks, not mid, "no load/unload during a multi-chunk request",
              f"{dur:.1f}s, {len(out)} chars out"
              + ("" if not mid else f"  <- {mid[0][1]}"))
        check(checks, dur > args.idle_timeout, "that request outlasted the idle window",
              f"{dur:.1f}s vs {args.idle_timeout:g}s idle")

        # --- D: the same, with overlapping requests ---------------------------
        results: list[str] = []
        errs: list[BaseException] = []

        def one() -> None:
            try:
                results.append(chat(base, text, args.timeout))
            except BaseException as exc:               # noqa: BLE001 - reported below
                errs.append(exc)

        t0 = time.monotonic()
        threads = [threading.Thread(target=one) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        t1 = time.monotonic()
        mid = [(t, ln) for t, ln in srv.window(t0, t1)
               if LOAD_RE.search(ln) or UNLOAD_RE.search(ln)]
        check(checks, not errs, "two overlapping requests both succeed",
              "both OK" if not errs else f"{errs[0]!r}")
        check(checks, not mid, "no load/unload during overlapping requests",
              f"{t1 - t0:.1f}s" + ("" if not mid else f"  <- {mid[0][1]}"))

        # --- E: idle at last, and it does reap ---------------------------------
        idle_start = time.monotonic()
        time.sleep(args.idle_timeout + REAPER_SLACK)
        unloads = [(t, ln) for t, ln in srv.window(idle_start, time.monotonic())
                   if UNLOAD_RE.search(ln)]
        rss_idle = srv.rss_mb()
        check(checks, bool(unloads), "the reaper does free it once idle",
              f"{unloads[0][1] if unloads else 'no unload bracket'}")
        check(checks, rss_idle < rss_loaded * 0.5, "idle footprint collapses",
              f"{rss_loaded:.0f} MB -> {rss_idle:.0f} MB")

        print(f"\nRSS  cold {rss_cold:.0f} MB | loaded {rss_loaded:.0f} MB | "
              f"after reaping {rss_idle:.0f} MB")
        return report(checks)
    finally:
        srv.stop()


if __name__ == "__main__":
    raise SystemExit(main())
