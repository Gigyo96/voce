#!/usr/bin/env python3
"""WER + Term Accuracy sul dataset personale (§10).

Dataset: ~/voce-dataset/<ts>.wav + <ts>.ref.txt (il .txt corretto a mano e rinominato).
Confronta solo le configurazioni che servono a decidere (§10.3):

  1. Parakeet senza boosting vs con boosting + dizionario (via `Voce transcribe`)
  2. Whisper large-v3-turbo con prompt di vocabolario, SOLO con --whisper e solo se il punto 1
     non raggiunge il target di Term Accuracy (richiede `pip install mlx-whisper`).

Riporta anche latenza p50/p95 e guardrail rate da ~/.voce/log.jsonl.

Uso:
  pip install jiwer
  python3 tools/eval.py                        # dataset e dizionario di default
  python3 tools/eval.py --models ultra v3      # confronto tra i due checkpoint Parakeet
  python3 tools/eval.py --whisper              # aggiunge Whisper turbo
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
import subprocess
import sys
import unicodedata
from pathlib import Path

HOME = Path.home()
DEFAULT_DATASET = HOME / "voce-dataset"
DEFAULT_DICT = HOME / ".voce" / "dictionary.json"
DEFAULT_LOG = HOME / ".voce" / "log.jsonl"
DEFAULT_BIN_CANDIDATES = [
    Path(__file__).resolve().parent.parent / "build" / "Voce.app" / "Contents" / "MacOS" / "Voce",
    Path("/Applications/Voce.app/Contents/MacOS/Voce"),
    HOME / "Applications" / "Voce.app" / "Contents" / "MacOS" / "Voce",
]

TARGET_WER = 0.05
TARGET_TERM_ACC = 0.95
TARGET_GUARDRAIL = 0.03


def normalize(text: str) -> str:
    """Testo normalizzato per il WER: minuscolo, senza punteggiatura, spazi singoli."""
    text = unicodedata.normalize("NFC", text).lower()
    text = re.sub(r"[^\w\s']", " ", text)
    text = text.replace("'", "' ")
    return " ".join(text.split())


def term_hits(ref: str, hyp: str, terms: list[str]) -> tuple[int, int]:
    """Occorrenze dei termini nel riferimento e quante sono scritte esattamente (case-sensitive) nell'ipotesi."""
    total = hit = 0
    for term in terms:
        pattern = r"(?<![\w])" + re.escape(term) + r"(?![\w])"
        n_ref = len(re.findall(pattern, ref))
        if n_ref:
            total += n_ref
            hit += min(n_ref, len(re.findall(pattern, hyp)))
    return hit, total


def find_bin(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit)
    for p in DEFAULT_BIN_CANDIDATES:
        if p.exists():
            return p
    sys.exit("Binario Voce non trovato: esegui scripts/build.sh oppure passa --bin")


def run_voce(binary: Path, wavs: list[Path], model: str, boost: bool, dict_path: Path) -> dict[str, dict]:
    cmd = [str(binary), "transcribe", "--model", model, "--dict", str(dict_path)]
    if not boost:
        cmd.append("--no-boost")
    cmd += [str(w) for w in wavs]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"Voce transcribe fallito:\n{out.stderr}")
    rows = [json.loads(line) for line in out.stdout.splitlines() if line.startswith("{")]
    return {r["file"]: r for r in rows}


def run_whisper(wavs: list[Path], terms: list[str]) -> dict[str, dict]:
    try:
        import mlx_whisper  # type: ignore
    except ImportError:
        sys.exit("Per --whisper serve `pip install mlx-whisper`")
    prompt = ", ".join(terms)
    res = {}
    for w in wavs:
        r = mlx_whisper.transcribe(str(w), path_or_hf_repo="mlx-community/whisper-large-v3-turbo",
                                   language="it", initial_prompt=prompt)
        res[str(w)] = {"final": r["text"].strip()}
    return res


def score(name: str, refs: dict[str, str], hyps: dict[str, str], terms: list[str]) -> dict:
    import jiwer

    keys = [k for k in refs if k in hyps]
    wer = jiwer.wer([normalize(refs[k]) for k in keys], [normalize(hyps[k]) for k in keys])
    hit = total = 0
    for k in keys:
        h, t = term_hits(refs[k], hyps[k], terms)
        hit += h
        total += t
    term_acc = hit / total if total else float("nan")
    return {"config": name, "n": len(keys), "wer": wer, "term_acc": term_acc, "term_n": total}


def log_metrics(log: Path) -> None:
    if not log.exists():
        return
    rows = [json.loads(l) for l in log.read_text().splitlines() if l.strip()]
    if not rows:
        return
    print(f"\nLog {log} ({len(rows)} dettature)")
    for label, subset in [("senza LLM", [r for r in rows if not r.get("llm") and r.get("guardrail") is None]),
                          ("con LLM", [r for r in rows if r.get("llm") or r.get("guardrail") is not None])]:
        ms = sorted(r["ms"] for r in subset if "ms" in r)
        if len(ms) >= 2:
            q = statistics.quantiles(ms, n=20)
            print(f"  latenza {label:9s}: p50 {statistics.median(ms):.0f} ms · p95 {q[18]:.0f} ms (n={len(ms)})")
        elif ms:
            print(f"  latenza {label:9s}: {ms[0]} ms (n=1)")
    llm_rows = [r for r in rows if r.get("llm") or r.get("guardrail") is not None]
    if llm_rows:
        rate = sum(1 for r in llm_rows if r.get("guardrail")) / len(llm_rows)
        flag = "OK" if rate < TARGET_GUARDRAIL else "SOPRA TARGET"
        print(f"  guardrail rate: {rate:.1%} ({flag}, target < {TARGET_GUARDRAIL:.0%})")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    ap.add_argument("--dict", type=Path, default=DEFAULT_DICT)
    ap.add_argument("--log", type=Path, default=DEFAULT_LOG)
    ap.add_argument("--bin")
    ap.add_argument("--models", nargs="+", default=["ultra"], choices=["ultra", "v3"])
    ap.add_argument("--whisper", action="store_true", help="aggiunge Whisper large-v3-turbo con prompt (mlx-whisper)")
    ap.add_argument("--show-errors", action="store_true", help="stampa i campioni con termini sbagliati")
    args = ap.parse_args()

    terms = json.loads(args.dict.read_text()).get("terms", []) if args.dict.exists() else []
    refs_paths = sorted(args.dataset.glob("*.ref.txt"))
    if not refs_paths:
        print(f"Nessun <ts>.ref.txt in {args.dataset}. Attiva saveSamples, correggi i .txt e rinominali in .ref.txt.")
        log_metrics(args.log)
        return

    wavs, refs = [], {}
    for r in refs_paths:
        wav = r.with_name(r.name.replace(".ref.txt", ".wav"))
        if wav.exists():
            wavs.append(wav)
            refs[str(wav)] = r.read_text().strip()
    print(f"{len(wavs)} campioni · {len(terms)} termini nel dizionario")

    binary = find_bin(args.bin)
    results = []
    outputs: dict[str, dict[str, str]] = {}
    for model in args.models:
        for boost in (False, True):
            name = f"parakeet-{model}" + (" + boost + dizionario" if boost else " (grezzo)")
            rows = run_voce(binary, wavs, model, boost, args.dict)
            hyps = {k: (v["final"] if boost else v["raw"]) for k, v in rows.items()}
            outputs[name] = hyps
            res = score(name, refs, hyps, terms)
            res["asr_ms_p50"] = statistics.median(int(v["asr_ms"]) for v in rows.values())
            results.append(res)

    if args.whisper:
        hyps = {k: v["final"] for k, v in run_whisper(wavs, terms).items()}
        outputs["whisper-turbo + prompt"] = hyps
        results.append(score("whisper-turbo + prompt", refs, hyps, terms))

    print(f"\n{'configurazione':42s} {'n':>4s} {'WER':>7s} {'TermAcc':>8s} {'ASR p50':>8s}")
    for r in results:
        asr = f"{r['asr_ms_p50']:.0f} ms" if "asr_ms_p50" in r else "—"
        print(f"{r['config']:42s} {r['n']:4d} {r['wer']:7.2%} {r['term_acc']:8.1%} {asr:>8s}")
    print(f"target: WER < {TARGET_WER:.0%}, Term Accuracy > {TARGET_TERM_ACC:.0%}")

    best = max((r for r in results if "boost" in r["config"]), key=lambda r: r["term_acc"], default=None)
    if best and best["term_acc"] == best["term_acc"]:
        if best["term_acc"] >= TARGET_TERM_ACC:
            print("→ Parakeet + boosting raggiunge il target: nessun secondo engine (Appendice A).")
        elif not args.whisper:
            print("→ Term Accuracy sotto target: prova `--whisper` e/o arricchisci `replace` nel dizionario.")

    if args.show_errors and terms:
        name = best["config"] if best else next(iter(outputs))
        print(f"\nErrori sui termini ({name}):")
        for k, hyp in outputs[name].items():
            h, t = term_hits(refs[k], hyp, terms)
            if h < t:
                print(f"- {Path(k).name}\n  ref: {refs[k]}\n  hyp: {hyp}")

    log_metrics(args.log)


if __name__ == "__main__":
    main()
