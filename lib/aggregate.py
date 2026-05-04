#!/usr/bin/env python3
"""Aggregate per-run CSVs into summary.csv and report.md for a results dir.

Usage: aggregate.py <results_root>

Reads <results_root>/<condition>/run_NN/{rtf,cpu,gpu,io,cam_hz}.csv for every
condition, computes per-run headline metrics, then per-condition median + IQR
across runs, and finally a delta vs the first condition listed.
"""
from __future__ import annotations

import csv
import json
import statistics
import sys
from pathlib import Path


def quantile(values: list[float], q: float) -> float:
    if not values:
        return float("nan")
    s = sorted(values)
    if len(s) == 1:
        return s[0]
    pos = (len(s) - 1) * q
    lo = int(pos)
    hi = min(lo + 1, len(s) - 1)
    frac = pos - lo
    return s[lo] * (1 - frac) + s[hi] * frac


def safe_floats(rows: list[dict], col: str) -> list[float]:
    out = []
    for r in rows:
        v = r.get(col, "")
        try:
            out.append(float(v))
        except (TypeError, ValueError):
            pass
    return out


def read_csv(p: Path) -> list[dict]:
    if not p.exists() or p.stat().st_size == 0:
        return []
    with p.open() as f:
        return list(csv.DictReader(f))


def run_metrics(run_dir: Path) -> dict:
    """Compute headline metrics for a single run."""
    rtf_rows = read_csv(run_dir / "rtf.csv")
    cpu_rows = read_csv(run_dir / "cpu.csv")
    gpu_rows = read_csv(run_dir / "gpu.csv")
    io_rows = read_csv(run_dir / "io.csv")
    cam_rows = read_csv(run_dir / "cam_hz.csv")

    rtf = safe_floats(rtf_rows, "rtf")
    cpu_tot = safe_floats(cpu_rows, "cpu_pct_total")
    rss = safe_floats(cpu_rows, "rss_kb")
    gpu_util = safe_floats(gpu_rows, "gpu_util_pct")
    vram = safe_floats(gpu_rows, "mem_used_mb")
    power = safe_floats(gpu_rows, "power_w")

    # iostat: aggregate writes across all devices per second, then take median.
    io_w = safe_floats(io_rows, "w_mb_s")

    cam_hz = safe_floats(cam_rows, "hz_inst")

    return {
        "n_rtf_samples": len(rtf),
        "rtf_p50": quantile(rtf, 0.5),
        "rtf_p10": quantile(rtf, 0.1),
        "cpu_p50_pct": quantile(cpu_tot, 0.5) if cpu_tot else float("nan"),
        "rss_peak_mb": (max(rss) / 1024.0) if rss else float("nan"),
        "gpu_util_p50_pct": quantile(gpu_util, 0.5) if gpu_util else float("nan"),
        "vram_peak_mb": max(vram) if vram else float("nan"),
        "power_p50_w": quantile(power, 0.5) if power else float("nan"),
        "io_w_p50_mb_s": quantile(io_w, 0.5) if io_w else float("nan"),
        "cam_hz_mean": (sum(cam_hz) / len(cam_hz)) if cam_hz else float("nan"),
    }


def cond_summary(per_run: list[dict]) -> dict:
    """Per-condition median + IQR across runs, for each metric."""
    if not per_run:
        return {}
    cols = list(per_run[0].keys())
    out: dict[str, dict[str, float]] = {}
    for c in cols:
        vals = [r[c] for r in per_run if not (isinstance(r[c], float) and r[c] != r[c])]
        if not vals:
            out[c] = {"p50": float("nan"), "p25": float("nan"), "p75": float("nan"), "n": 0}
            continue
        out[c] = {
            "p50": quantile(vals, 0.5),
            "p25": quantile(vals, 0.25),
            "p75": quantile(vals, 0.75),
            "n": len(vals),
        }
    return out


def fmt(v: float, prec: int = 2) -> str:
    if v != v:  # NaN
        return "n/a"
    if abs(v) >= 1000:
        return f"{v:.0f}"
    return f"{v:.{prec}f}"


def fmt_iqr(s: dict[str, float], prec: int = 2) -> str:
    return f"{fmt(s['p50'], prec)} [{fmt(s['p25'], prec)}, {fmt(s['p75'], prec)}]"


def delta_pct(a: float, b: float) -> str:
    if a != a or b != b or a == 0:
        return "n/a"
    return f"{(b - a) / abs(a) * 100:+.1f}%"


def iqrs_overlap(a: dict[str, float], b: dict[str, float]) -> bool:
    return not (a["p75"] < b["p25"] or b["p75"] < a["p25"])


METRIC_ORDER = [
    ("rtf_p50",         "RTF (median)",          4),
    ("rtf_p10",         "RTF p10 (worst tail)",  4),
    ("cam_hz_mean",     "Camera Hz (mean)",      2),
    ("cpu_p50_pct",     "CPU% (median, server)", 1),
    ("rss_peak_mb",     "RSS peak (MB)",         0),
    ("gpu_util_p50_pct","GPU util% (median)",    1),
    ("vram_peak_mb",    "VRAM peak (MB)",        0),
    ("power_p50_w",     "GPU power (median W)",  1),
    ("io_w_p50_mb_s",   "Disk write MB/s (median)", 2),
]


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = Path(sys.argv[1])
    if not root.is_dir():
        print(f"not a directory: {root}", file=sys.stderr)
        return 2

    conditions: dict[str, list[dict]] = {}
    for cond_dir in sorted(p for p in root.iterdir() if p.is_dir()):
        if cond_dir.name in ("build-logs",):
            continue
        run_dirs = sorted(p for p in cond_dir.iterdir() if p.is_dir() and p.name.startswith("run_"))
        if not run_dirs:
            continue
        runs = [run_metrics(rd) for rd in run_dirs]
        conditions[cond_dir.name] = runs

    if not conditions:
        print("no conditions found", file=sys.stderr)
        return 1

    summaries = {name: cond_summary(runs) for name, runs in conditions.items()}

    # summary.csv
    summary_path = root / "summary.csv"
    with summary_path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["condition", "metric", "p25", "p50", "p75", "n"])
        for cond, sm in summaries.items():
            for m in [k for k, _, _ in METRIC_ORDER]:
                if m in sm:
                    s = sm[m]
                    w.writerow([cond, m, s["p25"], s["p50"], s["p75"], s["n"]])

    # report.md
    cond_names = list(summaries.keys())
    base = cond_names[0]
    report_path = root / "report.md"
    with report_path.open("w") as f:
        f.write(f"# Bench report — {root.name}\n\n")
        f.write(f"Conditions: {', '.join(cond_names)}\n\n")
        f.write(f"Baseline (delta reference): `{base}`\n\n")

        # Header
        cols = ["Metric"] + cond_names + [f"delta vs {base}"]
        f.write("| " + " | ".join(cols) + " |\n")
        f.write("| " + " | ".join(["---"] * len(cols)) + " |\n")

        for key, label, prec in METRIC_ORDER:
            row = [label]
            base_s = summaries[base].get(key)
            for cond in cond_names:
                s = summaries[cond].get(key)
                row.append(fmt_iqr(s, prec) if s else "n/a")
            if base_s and len(cond_names) > 1:
                other = cond_names[1]
                other_s = summaries[other].get(key)
                if other_s:
                    delta = delta_pct(base_s["p50"], other_s["p50"])
                    overlap = iqrs_overlap(base_s, other_s)
                    marker = "" if overlap else " *"
                    row.append(f"{delta}{marker}")
                else:
                    row.append("n/a")
            else:
                row.append("n/a")
            f.write("| " + " | ".join(row) + " |\n")

        f.write("\n_`*` = IQRs do not overlap (informally significant)._\n\n")

        # Per-run dump for transparency.
        f.write("## Per-run details\n\n")
        for cond, runs in conditions.items():
            f.write(f"### {cond}\n\n")
            f.write("| run | rtf_p50 | rtf_p10 | cam_hz_mean | cpu_p50 | gpu_util_p50 | vram_peak_mb |\n")
            f.write("|---|---|---|---|---|---|---|\n")
            for i, r in enumerate(runs, 1):
                f.write(f"| {i:02d} | {fmt(r['rtf_p50'],4)} | {fmt(r['rtf_p10'],4)} | "
                        f"{fmt(r['cam_hz_mean'],2)} | {fmt(r['cpu_p50_pct'],1)} | "
                        f"{fmt(r['gpu_util_p50_pct'],1)} | {fmt(r['vram_peak_mb'],0)} |\n")
            f.write("\n")

    print(f"wrote {summary_path}")
    print(f"wrote {report_path}")

    # Echo a tight summary to stdout.
    for key, label, prec in METRIC_ORDER:
        line = [label.ljust(28)]
        for cond in cond_names:
            s = summaries[cond].get(key)
            line.append(fmt_iqr(s, prec).ljust(22))
        print(" | ".join(line))
    return 0


if __name__ == "__main__":
    sys.exit(main())
