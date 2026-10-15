#!/usr/bin/env python3
"""Recompute Tables 2, 3 and 4 of the LADC 2026 paper from the processed runs.

Input: data/june2026/processed/paper_runs.csv (= all_runs.csv filtered to
phase == "fault" and batch == 1; 135 runs). Passing all_runs.csv also works,
since the same filter is applied here.

Usage:
    python scripts/analysis/paper_tables.py [--csv PATH]
"""
from __future__ import annotations

import argparse
from pathlib import Path

import pandas as pd

REPO = Path(__file__).resolve().parents[2]
DEFAULT_CSV = REPO / "data" / "june2026" / "processed" / "paper_runs.csv"
CLS = ["ONE", "QUORUM", "ALL"]


def fmt(g: pd.DataFrame) -> pd.Series:
    return g["mean"].map("{:.2f}".format) + " ± " + g["std"].map("{:.2f}".format)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default=str(DEFAULT_CSV))
    args = ap.parse_args()

    d = pd.read_csv(args.csv)
    d = d[(d.phase == "fault") & (d.batch == 1)].copy()
    print(f"runs: {len(d)}  (phase == fault, batch == 1)\n")

    # Table 2: error rate (%) per fault x CL, n = 9 per cell (3 loads x 3 reps)
    d["error_rate_pct"] = 100 * d.return_error / (d.return_ok + d.return_error)
    t2 = d[d.fault_type.isin(["node_crash", "coord_crash", "net_partition"])]
    g = t2.groupby(["fault_type", "consistency"]).error_rate_pct.agg(["mean", "std", "count"])
    print("Table 2 - error rate (%), mean ± sd")
    print(fmt(g).unstack()[CLS].reindex(["node_crash", "coord_crash", "net_partition"]))
    print("n per cell:", sorted(int(x) for x in g["count"].unique()), "\n")

    # Table 3: MTTR (s) = mttr_repair_s (fault removal -> nodetool 5/5 UN), n = 27
    t3 = d[d.fault_type.isin(["node_crash", "coord_crash", "net_partition"])]
    g = t3.groupby("fault_type").mttr_repair_s.agg(["mean", "std", "min", "max", "count"])
    print("Table 3 - MTTR (s), column mttr_repair_s")
    print(g.reindex(["node_crash", "coord_crash", "net_partition"]).round(2), "\n")

    # Table 4: throughput degradation (%) under timing faults, n = 9 per cell
    t4 = d[d.fault_type.isin(["net_delay", "net_loss"])]
    g = t4.groupby(["fault_type", "consistency"]).degradation_pct.agg(["mean", "std", "count"])
    print("Table 4 - degradation_pct (%), mean ± sd")
    print(fmt(g).unstack()[CLS])
    print("n per cell:", sorted(int(x) for x in g["count"].unique()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
