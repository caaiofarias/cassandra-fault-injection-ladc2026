#!/usr/bin/env python3
"""
parser.py (v2) — lê data/raw/{workload,load,meta,fault} e gera data/processed/.

Mudanças v2:
  - Se data/raw/fault/<run_id>.json existir, enriquece a linha com:
      target_node, recovery_confirmed,
      fault_injected_s, fault_removed_s, fault_recovered_s
      (todos relativos ao t_script_start do fault_inject)
      mttr_repair_s    = t_recovery_confirmed - t_fault_removed
      mttr_total_s     = t_recovery_confirmed - t_fault_injected
  - Parseia o timeseries do YCSB stderr ("N sec: ... current ops/sec; ...")
    e calcula, alinhado ao tempo do fault:
      thr_pre_fault_ops, thr_during_fault_ops, thr_post_fault_ops
      degradation_pct  = 1 - (thr_during / thr_pre)
      (use thr ratio como proxy de availability — ver nota na docstring)

NOTA sobre "availability":
  O YCSB com -s emite contagem agregada (ops totais) por janela mas não
  contagem de erros por janela. Logo, *availability real* (1 - error_rate)
  por janela não é extraível desse log. Reportamos throughput ratio durante
  a falha como medida de *performability*, que é a métrica de fato usada
  por Gomes 2019 e literatura correlata. Para availability stricto sensu,
  habilitar `-p measurementtype=timeseries` no YCSB em estudos futuros.

É idempotente: por padrão pula runs cujo CSV já existe (use --force para refazer).

Uso:
    python parser.py [--root .] [--force]
"""
from __future__ import annotations
import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import pandas as pd

# ---- regex do formato -s do YCSB ----
SECTION_RE = re.compile(r"^\[(?P<sec>[A-Z\-_]+)\],\s*(?P<key>[^,]+),\s*(?P<val>.+?)\s*$")
RETURN_RE = re.compile(r"^\[(?P<sec>[A-Z\-_]+)\],\s*Return=(?P<status>\w+),\s*(?P<n>\d+)")

# Linha de status periodico do YCSB (vai pro stderr; capturado via 2>&1):
#  2026-06-12 03:29:18:123 60 sec: 230456 operations; 3841.2 current ops/sec; [READ ...]
STATUS_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}:\d+)\s+"
    r"(?P<sec>\d+)\s+sec:\s+(?P<ops>\d+)\s+operations;\s+"
    r"(?P<cur>[\d.]+)\s+current ops/sec"
)

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


def parse_ts(ts_str: str) -> float:
    """Converte '2026-06-12 03:29:18:123' em epoch (UTC; YCSB usa hora local).

    Como o YCSB imprime sem timezone, assumimos UTC (a VM está em UTC).
    Se mudar isso, ajustar aqui.
    """
    # formato com millis depois do segundo: 'YYYY-MM-DD HH:MM:SS:mmm'
    head, ms = ts_str.rsplit(":", 1)
    dt = datetime.strptime(head, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
    return dt.timestamp() + int(ms) / 1000.0


def parse_workload_log(path: Path) -> tuple[dict, list[tuple[float, int, float]]]:
    """Retorna (metricas_agregadas, timeseries).

    timeseries: lista de (epoch, cum_ops, current_ops_per_sec).
    """
    metrics: dict = {}
    counts = {"read_count": 0, "update_count": 0, "return_ok": 0, "return_error": 0}
    timeseries: list[tuple[float, int, float]] = []

    if not path.exists():
        return {}, []

    for line in path.read_text(errors="replace").splitlines():
        s = STATUS_RE.match(line)
        if s:
            try:
                timeseries.append((parse_ts(s["ts"]), int(s["ops"]), float(s["cur"])))
            except Exception:
                pass
            continue
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
    return metrics, timeseries


def parse_fault_json(path: Path) -> dict:
    """Lê o JSON do fault_inject.sh e calcula campos derivados."""
    if not path.exists():
        return {}
    try:
        d = json.loads(path.read_text())
    except json.JSONDecodeError:
        return {"fault_json_error": True}

    out: dict = {
        "fault_target_node": d.get("target_node"),
        "fault_recovery_confirmed": d.get("recovery_confirmed"),
    }
    t_start = d.get("t_script_start_epoch")
    t_inj   = d.get("t_fault_injected_epoch")
    t_rem   = d.get("t_fault_removed_epoch")
    t_rec   = d.get("t_recovery_confirmed_epoch")

    if t_start is not None:
        if t_inj is not None: out["fault_injected_s"]  = round(t_inj - t_start, 3)
        if t_rem is not None: out["fault_removed_s"]   = round(t_rem - t_start, 3)
        if t_rec is not None: out["fault_recovered_s"] = round(t_rec - t_start, 3)

    if t_rem is not None and t_rec is not None:
        out["mttr_repair_s"] = round(t_rec - t_rem, 3)
    if t_inj is not None and t_rec is not None:
        out["mttr_total_s"] = round(t_rec - t_inj, 3)

    return out


def compute_windowed_throughput(
    timeseries: list[tuple[float, int, float]],
    t_inject: Optional[float],
    t_remove: Optional[float],
    warmup_discard_s: float = 30.0,
) -> dict:
    """Calcula throughput médio nas janelas pre/durante/pos falha.

    Usa diferencas de cum_ops entre samples para nao depender do 'current'
    arredondado. Cada sample tipicamente sai a cada 10s.

    A janela pre-falha descarta os primeiros `warmup_discard_s` segundos
    (warm-up da JVM/driver) para medir throughput de regime estavel, evitando
    subestimar o baseline pre-falha. Se a janela pre ficar curta demais apos
    o descarte, cai de volta para a janela inteira.
    """
    if not timeseries or t_inject is None or t_remove is None:
        return {}

    samples = sorted(timeseries)  # por epoch
    out = {}

    def avg_thr(t0: float, t1: float) -> Optional[float]:
        in_window = [s for s in samples if t0 <= s[0] <= t1]
        if len(in_window) < 2:
            return None
        ops_delta = in_window[-1][1] - in_window[0][1]
        dt = in_window[-1][0] - in_window[0][0]
        return ops_delta / dt if dt > 0 else None

    t_first = samples[0][0]
    t_last  = samples[-1][0]

    # janela pre: descarta warm-up. Se sobrar < 2 samples, usa janela inteira.
    t_pre_start = t_first + warmup_discard_s
    pre = avg_thr(t_pre_start, t_inject)
    if pre is None:
        pre = avg_thr(t_first, t_inject)  # fallback: janela inteira
        out["thr_pre_warmup_discarded"] = False
    else:
        out["thr_pre_warmup_discarded"] = True

    dur  = avg_thr(t_inject, t_remove)
    post = avg_thr(t_remove, t_last)

    if pre is not None: out["thr_pre_fault_ops"]    = round(pre, 2)
    if dur is not None: out["thr_during_fault_ops"] = round(dur, 2)
    if post is not None: out["thr_post_fault_ops"]   = round(post, 2)
    if pre is not None and dur is not None and pre > 0:
        out["degradation_pct"] = round((1.0 - dur / pre) * 100.0, 2)
    return out


# ordem das colunas no CSV final
COLUMN_ORDER = [
    "run_id", "timestamp_utc", "phase", "batch", "consistency", "threads", "rep",
    "fault_type", "fault_start_offset_s", "fault_duration_s",
    "fault_target_node", "fault_recovery_confirmed",
    "fault_injected_s", "fault_removed_s", "fault_recovered_s",
    "mttr_repair_s", "mttr_total_s",
    "thr_pre_fault_ops", "thr_during_fault_ops", "thr_post_fault_ops",
    "thr_pre_warmup_discarded",
    "degradation_pct",
    "rf", "records", "operations", "workload", "cluster_nodes",
    "cassandra_version", "env",
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
    fault_json = raw_root / "fault" / f"{run_id}.json"

    metrics, timeseries = parse_workload_log(wl_log)
    fault = parse_fault_json(fault_json)

    # janelas de throughput precisam dos timestamps absolutos do fault
    if fault_json.exists():
        try:
            d = json.loads(fault_json.read_text())
            wins = compute_windowed_throughput(
                timeseries,
                d.get("t_fault_injected_epoch"),
                d.get("t_fault_removed_epoch"),
            )
        except Exception:
            wins = {}
    else:
        wins = {}

    return {**meta, **metrics, **fault, **wins}


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
        for col in COLUMN_ORDER:
            if col not in df.columns:
                df[col] = pd.NA
        df = df[COLUMN_ORDER]
        df.to_csv(out_csv, index=False)
        n_new += 1
        extra = ""
        if pd.notna(row.get("mttr_repair_s")):
            extra = f"  mttr_repair={row['mttr_repair_s']}s  degradation={row.get('degradation_pct')}%"
        print(f"[ok] {run_id}  thr={row.get('throughput_ops')}{extra}")

    all_csvs = sorted(runs_dir.glob("*.csv"))
    if all_csvs:
        big = pd.concat((pd.read_csv(c) for c in all_csvs), ignore_index=True)
        big = big.sort_values(["phase", "fault_type", "consistency", "threads", "rep", "timestamp_utc"])
        out_all = root / "data" / "processed" / "all_runs.csv"
        big.to_csv(out_all, index=False)
        print(f"\n[agregado] {len(big)} runs -> {out_all}")

    print(f"[fim] {n_new} novos runs parseados.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())