#!/usr/bin/env python3
"""
parse_runs.py — lê data/raw/{workload,load,meta} e gera data/processed/.

Para cada run_id encontrado em data/raw/meta/*.json:
  - parseia o workload log correspondente
  - junta metadados + métricas
  - escreve data/processed/runs/<run_id>.csv  (1 linha)
Depois concatena todos em data/processed/all_runs.csv.

É idempotente: por padrão pula runs cujo CSV já existe (use --force para refazer).

Uso:
    python parse_runs.py [--root .] [--force]
"""
from __future__ import annotations
import argparse
import json
import re
import sys
from pathlib import Path

import pandas as pd

# ---- regex do formato -s do YCSB ----
# Linhas como:
# [OVERALL], Throughput(ops/sec), 5950.12
# [READ], AverageLatency(us), 5473.1
# [READ], 99thPercentileLatency(us), 30670.0
# [READ], Return=OK, 25000
SECTION_RE = re.compile(r"^\[(?P<sec>[A-Z\-_]+)\],\s*(?P<key>[^,]+),\s*(?P<val>.+?)\s*$")

# mapeia (secao, chave_normalizada) -> coluna no CSV
# latências do YCSB vêm em microssegundos; convertemos p/ ms
FIELD_MAP = {
    ("OVERALL", "Throughput(ops/sec)"): ("throughput_ops", 1.0),
    ("OVERALL", "RunTime(ms)"):         ("runtime_ms", 1.0),
    ("READ", "AverageLatency(us)"):     ("read_avg_ms", 1e-3),
    ("READ", "95thPercentileLatency(us)"): ("read_p95_ms", 1e-3),
    ("READ", "99thPercentileLatency(us)"): ("read_p99_ms", 1e-3),
    ("UPDATE", "AverageLatency(us)"):   ("update_avg_ms", 1e-3),
    ("UPDATE", "95thPercentileLatency(us)"): ("update_p95_ms", 1e-3),
    ("UPDATE", "99thPercentileLatency(us)"): ("update_p99_ms", 1e-3),
}

# contagens de retorno (somadas por seção)
RETURN_RE = re.compile(r"^\[(?P<sec>[A-Z\-_]+)\],\s*Return=(?P<status>\w+),\s*(?P<n>\d+)")


def parse_workload_log(path: Path) -> dict:
    """Extrai métricas de um log de workload YCSB (-s)."""
    metrics: dict[str, float] = {}
    counts = {"read_count": 0, "update_count": 0, "return_ok": 0, "return_error": 0}
    if not path.exists():
        return {}
    for line in path.read_text(errors="replace").splitlines():
        m = SECTION_RE.match(line)
        if m:
            sec, key, val = m["sec"], m["key"].strip(), m["val"].strip()
            mapped = FIELD_MAP.get((sec, key))
            if mapped:
                col, factor = mapped
                try:
                    metrics[col] = float(val) * factor
                except ValueError:
                    pass
        r = RETURN_RE.match(line)
        if r:
            sec, status, n = r["sec"], r["status"], int(r["n"])
            if status == "OK":
                counts["return_ok"] += n
            else:
                counts["return_error"] += n
            if sec == "READ":
                counts["read_count"] += n
            elif sec == "UPDATE":
                counts["update_count"] += n
    metrics.update(counts)
    return metrics


# ordem das colunas no CSV final
COLUMN_ORDER = [
    "run_id", "timestamp_utc", "phase", "consistency", "threads", "rep",
    "fault_type", "fault_start_offset_s", "fault_duration_s",
    "rf", "records", "operations", "workload", "cluster_nodes",
    "cassandra_version", "env", "git_commit",
    "throughput_ops", "runtime_ms",
    "read_avg_ms", "read_p95_ms", "read_p99_ms", "read_count",
    "update_avg_ms", "update_p95_ms", "update_p99_ms", "update_count",
    "return_ok", "return_error",
    "notes",
]


def build_row(meta_path: Path, raw_root: Path) -> dict:
    meta = json.loads(meta_path.read_text())
    run_id = meta["run_id"]
    wl_log = raw_root / "workload" / f"{run_id}.log"
    metrics = parse_workload_log(wl_log)
    row = {**meta, **metrics}
    return row


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".", help="raiz do projeto (contém data/)")
    ap.add_argument("--force", action="store_true", help="reparseia mesmo se CSV existir")
    args = ap.parse_args()

    root = Path(args.root)
    raw_root = root / "data" / "raw"
    meta_dir = raw_root / "meta"
    runs_dir = root / "data" / "processed" / "runs"
    runs_dir.mkdir(parents=True, exist_ok=True)

    if not meta_dir.exists():
        print(f"[erro] não encontrei {meta_dir}", file=sys.stderr)
        return 1

    metas = sorted(meta_dir.glob("*.json"))
    if not metas:
        print(f"[aviso] nenhum meta em {meta_dir}")
        return 0

    n_new = 0
    for meta_path in metas:
        run_id = meta_path.stem
        out_csv = runs_dir / f"{run_id}.csv"
        if out_csv.exists() and not args.force:
            continue
        row = build_row(meta_path, raw_root)
        df = pd.DataFrame([row])
        # garante todas as colunas, na ordem
        for col in COLUMN_ORDER:
            if col not in df.columns:
                df[col] = pd.NA
        df = df[COLUMN_ORDER]
        df.to_csv(out_csv, index=False)
        n_new += 1
        print(f"[ok] {run_id}  thr={row.get('throughput_ops')}  "
              f"read_avg={row.get('read_avg_ms')}")

    # ---- agrega tudo ----
    all_csvs = sorted(runs_dir.glob("*.csv"))
    if all_csvs:
        big = pd.concat((pd.read_csv(c) for c in all_csvs), ignore_index=True)
        big = big.sort_values(["phase", "consistency", "threads", "rep", "timestamp_utc"])
        out_all = root / "data" / "processed" / "all_runs.csv"
        big.to_csv(out_all, index=False)
        print(f"\n[agregado] {len(big)} runs -> {out_all}")

    print(f"[fim] {n_new} novos runs parseados.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())