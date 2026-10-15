#!/usr/bin/env python3
"""
make_dilution.py — explica visualmente a DILUIÇÃO OPERACIONAL.

Responde à pergunta: por que a taxa de erro média sob CL=ALL é ~24%, se cada nó
detém ~58-62% do espaço de chaves?

Resposta em três painéis:
  1. Vazão por janela  -> a janela PÓS-falta é lenta, e é isso que distorce tudo.
  2. Tempo vs Operações -> a janela de falta vale 33% do relógio, mas ~40% das
                           operações. A taxa de erro é média POR OPERAÇÃO.
  3. A reconciliação    -> 24,3% / 0,403 = 63%, que cai dentro da faixa de
                           58-62% do espaço de chaves por nó.

Lê o all_runs.csv de batch 1, CL=ALL.

Uso:
    python make_dilution.py --csv <all_runs.csv> --lang pt --out fig_dilution_pt.pdf
"""
from __future__ import annotations
import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

REPO = Path(__file__).resolve().parents[2]
DATA = REPO / "data" / "june2026"
import numpy as np
import pandas as pd
from matplotlib.patches import Patch

LABELS = {
    "pt": {
        "sup": "Por que a taxa de erro média sob CL=ALL é ~24%, e não ~60%?",
        "p1": "1. A vazão não é constante entre as janelas",
        "p2": "2. Fatia do relógio  ×  fatia das operações",
        "p3": "3. A reconciliação",
        "pre": "pré-falta", "dur": "durante\na falta", "post": "pós-falta",
        "thr": "Vazão (ops/s)",
        "healthy": "média saudável\n(pré + pós)",
        "bytime": "por TEMPO", "byops": "por OPERAÇÕES",
        "share": "Fração da execução (%)",
        "faults": {"node_crash": "Crash de réplica",
                   "coord_crash": "Crash de coord.",
                   "net_partition": "Partição de rede"},
        "mean": "taxa média\n(Tabela 2)",
        "inst": "taxa medida dentro\nda janela de falta",
        "rate": "Taxa de erro (%)",
        "band": "espaço de chaves\npor nó (58-62%)",
        "note": ("A taxa de erro é uma média POR OPERAÇÃO, não por tempo. Como a janela pós-falta é lenta\n"
                 "(nó frio, hints, reingresso no gossip), a janela de falta concentra ~40% das operações\n"
                 "em apenas ~33% do tempo. Medida dentro da janela, a severidade real é ~56% nos três tipos de falta."),
    },
    "en": {
        "sup": "Why is the mean error rate under CL=ALL ~24%, and not ~60%?",
        "p1": "1. Throughput is not constant across windows",
        "p2": "2. Share of the clock  ×  share of the operations",
        "p3": "3. The reconciliation",
        "pre": "pre-fault", "dur": "during\nthe fault", "post": "post-fault",
        "thr": "Throughput (ops/s)",
        "healthy": "healthy mean\n(pre + post)",
        "bytime": "by TIME", "byops": "by OPERATIONS",
        "share": "Share of the run (%)",
        "faults": {"node_crash": "Replica crash",
                   "coord_crash": "Coordinator crash",
                   "net_partition": "Network partition"},
        "mean": "mean rate\n(Table 2)",
        "inst": "rate measured inside\nthe fault window",
        "rate": "Error rate (%)",
        "band": "key space\nper node (58-62%)",
        "note": ("The error rate is a PER-OPERATION mean, not a per-time one. Because the post-fault window is slow\n"
                 "(cold node, hints, gossip rejoin), the fault window concentrates ~40% of the operations\n"
                 "in only ~33% of the time. Measured inside the window, the real severity is ~56% for all three fault types."),
    },
}

ORDER = ["node_crash", "coord_crash", "net_partition"]
C_PRE, C_DUR, C_POST = "#4c8cbf", "#d1495b", "#8d99ae"
C_ACC = "#1E2761"


STATUS = re.compile(r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}:\d+)\s+\d+\s+sec:")
COUNT = re.compile(r"\[(?P<sec>[A-Z\-]+): Count=(?P<n>\d+)")
RUNID = re.compile(r"fault_(?P<cons>ONE|QUORUM|ALL)_t(?P<thr>\d+)_rep(?P<rep>\d+)_b1")


def _epoch(ts: str) -> float:
    head, ms = ts.rsplit(":", 1)
    dt = datetime.strptime(head, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
    return dt.timestamp() + int(ms) / 1000


def measure_in_window(logs_dir: Path) -> pd.Series:
    """Taxa de erro MEDIDA dentro da janela de falta (CL=ALL), a partir dos
    logs brutos. Conta apenas intervalos de 10 s inteiramente dentro da janela,
    para que as bordas parciais não diluam o valor."""
    out = {}
    for fj in sorted((logs_dir / "fault").glob("*.json")):
        m = RUNID.search(fj.stem)
        if not m or m["cons"] != "ALL":
            continue
        f = json.loads(fj.read_text())
        ft = f.get("fault_type")
        if ft not in ORDER:
            continue
        wl = logs_dir / "workload" / f"{fj.stem}.log"
        if not wl.exists():
            continue
        ti, tr = f["t_fault_injected_epoch"], f["t_fault_removed_epoch"]
        prev, tot, err = None, 0, 0
        for line in wl.read_text(errors="replace").splitlines():
            sm = STATUS.match(line)
            if not sm:
                continue
            t = _epoch(sm["ts"])
            t0 = prev if prev is not None else t - 10
            prev = t
            if not (t0 >= ti and t <= tr):
                continue
            for cm in COUNT.finditer(line):
                sec, n = cm["sec"], int(cm["n"])
                if sec.endswith("-FAILED"):
                    err += n; tot += n
                elif sec in ("READ", "UPDATE", "INSERT", "SCAN"):
                    tot += n
        if tot:
            out.setdefault(ft, []).append(100 * err / tot)
    return pd.Series({k: float(np.mean(v)) for k, v in out.items()}).reindex(ORDER)


def compute(csv: Path) -> pd.DataFrame:
    d = pd.read_csv(csv)
    d = d[(d.phase == "fault") & (d.batch == 1) & (d.consistency == "ALL")]
    d = d[d.fault_type.isin(ORDER)].copy()
    d["dur_pre"] = d.fault_injected_s
    d["dur_dur"] = d.fault_removed_s - d.fault_injected_s
    d["dur_post"] = d.runtime_ms / 1000 - d.fault_removed_s
    d["ops_pre"] = d.thr_pre_fault_ops * d.dur_pre
    d["ops_dur"] = d.thr_during_fault_ops * d.dur_dur
    d["ops_post"] = d.thr_post_fault_ops * d.dur_post
    tot_ops = d.ops_pre + d.ops_dur + d.ops_post
    tot_dur = d.dur_pre + d.dur_dur + d.dur_post
    d["f_ops"] = 100 * d.ops_dur / tot_ops
    d["f_time"] = 100 * d.dur_dur / tot_dur
    d["thr_healthy"] = (d.ops_pre + d.ops_post) / (d.dur_pre + d.dur_post)
    d["err_tot"] = 100 * d.return_error / (d.return_ok + d.return_error)
    d["err_dur"] = d.err_tot / (d.f_ops / 100)
    g = d.groupby("fault_type").mean(numeric_only=True).reindex(ORDER)
    return g


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default=str(DATA / "processed" / "paper_runs.csv"))
    ap.add_argument("--logs-dir", default=str(DATA / "raw"),
                    help="diretório com workload/ e fault/ (logs brutos)")
    ap.add_argument("--lang", choices=["pt", "en"], default="pt")
    ap.add_argument("--out", default="fig_dilution.pdf")
    args = ap.parse_args()
    L = LABELS[args.lang]
    g = compute(Path(args.csv))
    g["err_dur"] = measure_in_window(Path(args.logs_dir))   # medida, não derivada
    names = [L["faults"][f] for f in ORDER]
    x = np.arange(len(ORDER))

    fig, axes = plt.subplots(1, 3, figsize=(15.5, 4.6))

    # ---- painel 1: vazão por janela -------------------------------------
    ax = axes[0]
    w = 0.26
    ax.bar(x - w, g.thr_pre_fault_ops, w, color=C_PRE, label=L["pre"])
    ax.bar(x, g.thr_during_fault_ops, w, color=C_DUR, label=L["dur"].replace("\n", " "))
    ax.bar(x + w, g.thr_post_fault_ops, w, color=C_POST, label=L["post"])
    for i, v in enumerate(g.thr_healthy):
        ax.plot([i - 1.5 * w, i + 1.5 * w], [v, v], ls="--", lw=1.6, color="black", zorder=5)
    ax.plot([], [], ls="--", lw=1.6, color="black", label=L["healthy"].replace("\n", " "))
    ax.set_xticks(x); ax.set_xticklabels(names, fontsize=8.5)
    ax.set_ylabel(L["thr"], fontsize=9.5)
    ax.set_title(L["p1"], fontsize=10.5, fontweight="bold")
    ax.set_ylim(0, float(g.thr_pre_fault_ops.max()) * 1.42)
    ax.legend(fontsize=7.5, loc="upper left", ncol=2, framealpha=0.95)
    ax.grid(axis="y", alpha=0.3)
    ax.set_axisbelow(True)

    # ---- painel 2: tempo vs operações -----------------------------------
    ax = axes[1]
    w = 0.34
    b1 = ax.bar(x - w / 2 - 0.02, g.f_time, w, color=C_POST, label=L["bytime"])
    b2 = ax.bar(x + w / 2 + 0.02, g.f_ops, w, color=C_DUR, label=L["byops"])
    for b in list(b1) + list(b2):
        ax.text(b.get_x() + b.get_width() / 2, b.get_height() + 0.8,
                f"{b.get_height():.0f}%", ha="center", fontsize=9, fontweight="bold")
    for i in range(len(ORDER)):
        ax.annotate("", xy=(i + w / 2 + 0.02, g.f_ops.iloc[i] + 4.2),
                    xytext=(i - w / 2 - 0.02, g.f_time.iloc[i] + 4.2),
                    arrowprops=dict(arrowstyle="->", color=C_ACC, lw=1.4))
    ax.set_xticks(x); ax.set_xticklabels(names, fontsize=8.5)
    ax.set_ylabel(L["share"], fontsize=9.5)
    ax.set_ylim(0, 56)
    ax.set_title(L["p2"], fontsize=10.5, fontweight="bold")
    ax.legend(fontsize=8, loc="upper right", framealpha=0.95)
    ax.grid(axis="y", alpha=0.3)
    ax.set_axisbelow(True)

    # ---- painel 3: reconciliação ----------------------------------------
    ax = axes[2]
    ax.axhspan(58, 62, color="#f0c419", alpha=0.35, zorder=0)
    ax.set_xlim(-0.62, len(ORDER) + 0.10)
    ax.text(len(ORDER) - 0.52, 60, L["band"], fontsize=7.5, va="center",
            ha="left", style="italic", zorder=6)
    w = 0.34
    ax.bar(x - w / 2 - 0.02, g.err_tot, w, color=C_POST, label=L["mean"].replace("\n", " "))
    ax.bar(x + w / 2 + 0.02, g.err_dur, w, color=C_DUR, label=L["inst"].replace("\n", " "))
    for i in range(len(ORDER)):
        ax.text(i - w / 2 - 0.02, g.err_tot.iloc[i] + 1.2, f"{g.err_tot.iloc[i]:.1f}%",
                ha="center", fontsize=9, fontweight="bold")
        ax.text(i + w / 2 + 0.02, g.err_dur.iloc[i] + 1.2, f"{g.err_dur.iloc[i]:.1f}%",
                ha="center", fontsize=9, fontweight="bold")
        ax.annotate("", xy=(i + w / 2 + 0.02, g.err_dur.iloc[i] - 3),
                    xytext=(i - w / 2 - 0.02, g.err_tot.iloc[i] + 4),
                    arrowprops=dict(arrowstyle="->", color=C_ACC, lw=1.5))
    ax.set_xticks(x); ax.set_xticklabels(names, fontsize=8.5)
    ax.set_ylabel(L["rate"], fontsize=9.5)
    ax.set_ylim(0, 76)
    ax.set_title(L["p3"], fontsize=10.5, fontweight="bold")
    ax.legend(fontsize=8, loc="upper left", framealpha=0.95)
    ax.grid(axis="y", alpha=0.3)
    ax.set_axisbelow(True)

    fig.suptitle(L["sup"], fontsize=13, fontweight="bold", y=1.04)
    fig.text(0.5, -0.10, L["note"], ha="center", fontsize=8.5, color="#333333")
    fig.tight_layout()

    out = Path(args.out)
    fig.savefig(out, bbox_inches="tight")
    fig.savefig(out.with_suffix(".png"), dpi=140, bbox_inches="tight")
    print(f"figura de diluição gerada: {out} (+ .png)")

    print("\n-- valores usados --")
    cols = ["thr_pre_fault_ops", "thr_during_fault_ops", "thr_post_fault_ops",
            "thr_healthy", "f_time", "f_ops", "err_tot", "err_dur"]
    print(g[cols].round(1).to_string())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
