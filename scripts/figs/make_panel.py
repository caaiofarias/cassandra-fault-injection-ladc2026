#!/usr/bin/env python3
"""
make_panel.py — gera o PAINEL COMPOSTO das 3 falhas-chave (Figura 2 do artigo).

Monta uma única figura com 3 subgráficos lado a lado, a partir dos logs brutos
do YCSB + os JSONs de fault:
  1. Crash de réplica   -> taxa de erro ao longo do tempo
  2. Partição de rede   -> taxa de erro ao longo do tempo
  3. Atraso de rede     -> vazão ao longo do tempo

O tempo é realinhado ao instante de injeção da falta (t=0) e a janela de falta
é sombreada. Usa a repetição MEDIANA de cada célula (pela vazão pré-falta) para
evitar escolher um outlier.

NOTA: este script lê os LOGS BRUTOS (workload/*.log + fault/*.json), não o
all_runs.csv — a série temporal de 10 em 10s não é salva no CSV.

Uso:
    python make_panel.py --logs-dir . --out panel_3faults.pdf [--threads 50] [--lang pt]

    --logs-dir : diretório que contém workload/ e fault/
    --threads  : nível de carga a plotar (default 50)
    --lang     : 'pt' ou 'en' (rótulos)
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

STATUS_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}:\d+)\s+(?P<sec>\d+)\s+sec:\s+"
    r"(?P<ops>\d+)\s+operations;\s+(?P<cur>[\d.]+)\s+current ops/sec"
)
COUNT_RE = re.compile(r"\[(?P<sec>[A-Z\-]+): Count=(?P<n>\d+)")
RUNID_RE = re.compile(r"fault_(?P<cons>ONE|QUORUM|ALL)_t(?P<thr>\d+)_rep(?P<rep>\d+)_b")

CONS_ORDER = ["ONE", "QUORUM", "ALL"]
COL = {"ONE": "#1f77b4", "QUORUM": "#ff7f0e", "ALL": "#d62728"}
MK = {"ONE": "o", "QUORUM": "s", "ALL": "^"}

LABELS = {
    "pt": {
        "crash": "Crash de réplica",
        "part": "Partição de rede",
        "delay": "Atraso de rede",
        "err": "Taxa de erro (%)",
        "thr": "Vazão (ops/s)",
        "x": "Tempo desde a injeção (s)",
        "sup": "Séries temporais de dependabilidade a {t} threads (repetição mediana)",
    },
    "en": {
        "crash": "Replica crash",
        "part": "Network partition",
        "delay": "Network delay",
        "err": "Error rate (%)",
        "thr": "Throughput (ops/s)",
        "x": "Time since injection (s)",
        "sup": "Dependability time series at {t} threads (median repetition)",
    },
}


def parse_ts(ts_str: str) -> float:
    head, ms = ts_str.rsplit(":", 1)
    dt = datetime.strptime(head, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
    return dt.timestamp() + int(ms) / 1000.0


def parse_series(path: Path):
    """Retorna [(epoch, cur_ops, error_rate_pct_da_janela), ...]."""
    out = []
    for line in Path(path).read_text(errors="replace").splitlines():
        m = STATUS_RE.match(line)
        if not m:
            continue
        try:
            ep = parse_ts(m["ts"])
            cur = float(m["cur"])
        except Exception:
            continue
        ok = fa = 0
        for cm in COUNT_RE.finditer(line):
            s, n = cm["sec"], int(cm["n"])
            if s.endswith("-FAILED"):
                fa += n
            elif s in ("READ", "UPDATE", "INSERT", "SCAN"):
                ok += n
        tot = ok + fa
        out.append((ep, cur, (fa / tot * 100 if tot else 0.0)))
    return out


def collect(logs_dir: Path):
    runs = {}
    for fj in (logs_dir / "fault").glob("*.json"):
        rid = fj.stem
        m = RUNID_RE.search(rid)
        if not m:
            continue
        try:
            fault = json.loads(fj.read_text())
        except Exception:
            continue
        wl = logs_dir / "workload" / f"{rid}.log"
        if not wl.exists():
            continue
        runs[(fault.get("fault_type"), m["cons"], int(m["thr"]), int(m["rep"]))] = \
            {"log": wl, "fault": fault}
    return runs


def median_rep(runs, ft, cons, thr):
    cands = []
    for rep in (1, 2, 3):
        k = (ft, cons, thr, rep)
        if k not in runs:
            continue
        ts = parse_series(runs[k]["log"])
        fault = runs[k]["fault"]
        ti = fault.get("t_fault_injected_epoch")
        if not ts or ti is None:
            continue
        t0 = ts[0][0]
        pre = [c for (t, c, e) in ts if t0 + 30 <= t < ti]
        cands.append((np.mean(pre) if pre else 0, rep, ts, fault))
    if not cands:
        return None
    cands.sort(key=lambda x: x[0])
    return cands[len(cands) // 2]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--logs-dir", default=str(DATA / "raw"))
    ap.add_argument("--out", default="panel_3faults.pdf")
    ap.add_argument("--threads", type=int, default=50)
    ap.add_argument("--lang", choices=["pt", "en"], default="en")
    args = ap.parse_args()

    L = LABELS[args.lang]
    thr = args.threads
    runs = collect(Path(args.logs_dir))

    panels = [
        ("node_crash", L["crash"], True),
        ("net_partition", L["part"], True),
        ("net_delay", L["delay"], False),
    ]
    plt.rcParams.update({"font.size": 10.5, "axes.labelsize": 10.5, "xtick.labelsize": 9.5, "ytick.labelsize": 9.5})
    fig, axes = plt.subplots(1, 3, figsize=(7.4, 2.75))
    for ax, (ft, title, use_err) in zip(axes, panels):
        rem_rel = []
        for cons in CONS_ORDER:
            sel = median_rep(runs, ft, cons, thr)
            if not sel:
                continue
            _, rep, ts, fault = sel
            ti = fault["t_fault_injected_epoch"]
            tr = fault["t_fault_removed_epoch"]
            xs = [t - ti for (t, c, e) in ts]
            ys = [(e if use_err else c) for (t, c, e) in ts]
            ax.plot(xs, ys, marker=MK[cons], ms=3, color=COL[cons], label=cons, lw=1.3)
            rem_rel.append(tr - ti)
        rem = np.median(rem_rel) if rem_rel else 90
        ax.axvspan(0, rem, alpha=0.12, color="red")
        ax.axvline(0, color="red", ls="--", lw=0.9, alpha=0.7)
        ax.axvline(rem, color="green", ls="--", lw=0.9, alpha=0.7)
        ax.set_xlabel(L["x"])
        ax.set_ylabel(L["err"] if use_err else L["thr"])
        ax.set_ylim(-2, 105) if use_err else ax.set_ylim(bottom=0)
        ax.set_title(title, fontsize=10.5)
        ax.grid(True, alpha=0.3)
    # legenda única acima dos painéis; o título geral fica na legenda da figura no LaTeX
    h, lab = axes[0].get_legend_handles_labels()
    fig.legend(h, lab, loc="upper center", ncol=3, frameon=False, fontsize=10,
               bbox_to_anchor=(0.5, 1.07))
    fig.tight_layout()
    out = Path(args.out)
    fig.savefig(out, bbox_inches="tight")
    fig.savefig(out.with_suffix(".png"), dpi=130, bbox_inches="tight")
    print(f"painel gerado: {out} (+ .png)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())