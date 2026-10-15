#!/usr/bin/env python3
"""
analyze_fault.py — análise da Fase 2 (fault injection) a partir do all_runs.csv.

Produz, separando as métricas pelo tipo de falha (cada uma com a métrica que faz
sentido fisicamente):

  - CRASH / PARTITION (falhas que geram erro de serviço):
      métrica principal = TAXA DE ERRO (return_error / total), por célula,
      com média e desvio entre reps. Tambem reporta disponibilidade observada
      durante a janela como (1 - taxa_erro).

  - DELAY / LOSS (timing failures, ~0 erro):
      métrica principal = DEGRADAÇÃO DE THROUGHPUT (%), confiável aqui pois
      sem erros inflando a janela "durante".

  - MTTR: reportado apenas para crash/partition (rejoin do gossip).
    Para delay/loss o "MTTR" mede só latência de poll e NÃO é tempo de reparo.

Também:
  - sinaliza runs suspeitos (clean/recovery=false, CV alto, outliers de erro)
  - exporta tabelas resumo em CSV para uso direto no artigo

Uso:
    python analyze_fault.py [--csv all_runs.csv] [--out-dir analysis]
"""
from __future__ import annotations
import argparse
from pathlib import Path

import numpy as np
import pandas as pd

CONS_ORDER = ["ONE", "QUORUM", "ALL"]
ERROR_FAULTS = ["node_crash", "coord_crash", "net_partition"]
TIMING_FAULTS = ["net_delay", "net_loss"]


def cv(series: pd.Series) -> float:
    """Coeficiente de variação (%) — robusto a média zero."""
    m = series.mean()
    if m == 0 or pd.isna(m):
        return 0.0
    return series.std() / m * 100.0


def order_cons(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df["consistency"] = pd.Categorical(df["consistency"], CONS_ORDER, ordered=True)
    return df.sort_values(["consistency", "threads"])


def load(csv_path: Path) -> pd.DataFrame:
    d = pd.read_csv(csv_path)
    d = d[d["phase"] == "fault"].copy()
    d["total_ops"] = d["return_ok"].fillna(0) + d["return_error"].fillna(0)
    d["error_rate_pct"] = np.where(
        d["total_ops"] > 0, d["return_error"] / d["total_ops"] * 100.0, np.nan
    )
    d["availability_pct"] = 100.0 - d["error_rate_pct"]
    return d


def table_error_faults(d: pd.DataFrame) -> pd.DataFrame:
    """Tabela por célula para falhas que geram erro: taxa de erro + MTTR."""
    rows = []
    sub = d[d["fault_type"].isin(ERROR_FAULTS)]
    for (ft, cons, thr), g in sub.groupby(["fault_type", "consistency", "threads"]):
        rows.append({
            "fault_type": ft,
            "consistency": cons,
            "threads": thr,
            "n_reps": len(g),
            "error_rate_mean_pct": round(g["error_rate_pct"].mean(), 3),
            "error_rate_std_pct": round(g["error_rate_pct"].std(ddof=1), 3) if len(g) > 1 else 0.0,
            "availability_mean_pct": round(g["availability_pct"].mean(), 3),
            "mttr_repair_mean_s": round(g["mttr_repair_s"].mean(), 1),
            "mttr_repair_std_s": round(g["mttr_repair_s"].std(ddof=1), 1) if len(g) > 1 else 0.0,
            "thr_pre_mean_ops": round(g["thr_pre_fault_ops"].mean(), 1),
        })
    out = pd.DataFrame(rows)
    return order_cons(out).reset_index(drop=True)


def table_timing_faults(d: pd.DataFrame) -> pd.DataFrame:
    """Tabela por célula para timing failures: degradação de throughput."""
    rows = []
    sub = d[d["fault_type"].isin(TIMING_FAULTS)]
    for (ft, cons, thr), g in sub.groupby(["fault_type", "consistency", "threads"]):
        rows.append({
            "fault_type": ft,
            "consistency": cons,
            "threads": thr,
            "n_reps": len(g),
            "degradation_mean_pct": round(g["degradation_pct"].mean(), 2),
            "degradation_std_pct": round(g["degradation_pct"].std(ddof=1), 2) if len(g) > 1 else 0.0,
            "thr_pre_mean_ops": round(g["thr_pre_fault_ops"].mean(), 1),
            "thr_during_mean_ops": round(g["thr_during_fault_ops"].mean(), 1),
            "thr_post_mean_ops": round(g["thr_post_fault_ops"].mean(), 1),
            "error_rate_mean_pct": round(g["error_rate_pct"].mean(), 4),
        })
    out = pd.DataFrame(rows)
    return order_cons(out).reset_index(drop=True)


def summary_matrix(d: pd.DataFrame) -> pd.DataFrame:
    """Matriz compacta falha × consistência (média sobre threads e reps).

    Reporta taxa de erro para crash/partition e degradação p/ delay/loss,
    numa única coluna 'headline' interpretável.
    """
    rows = []
    for ft in ERROR_FAULTS + TIMING_FAULTS:
        sub = d[d["fault_type"] == ft]
        for cons in CONS_ORDER:
            g = sub[sub["consistency"] == cons]
            if g.empty:
                continue
            if ft in ERROR_FAULTS:
                metric, val = "error_rate_pct", g["error_rate_pct"].mean()
            else:
                metric, val = "degradation_pct", g["degradation_pct"].mean()
            rows.append({
                "fault_type": ft, "consistency": cons,
                "headline_metric": metric, "value": round(val, 2),
            })
    return pd.DataFrame(rows)


def flag_suspect_runs(d: pd.DataFrame) -> pd.DataFrame:
    """Sinaliza runs que merecem inspeção manual."""
    flags = []
    for _, r in d.iterrows():
        reasons = []
        if r.get("fault_recovery_confirmed") is not True and str(r.get("fault_recovery_confirmed")).lower() != "true":
            reasons.append("recovery_nao_confirmado")
        if "clean_confirmed" in d.columns and str(r.get("clean_confirmed")).lower() == "false":
            reasons.append("clean_nao_confirmado")
        # erro inesperado: falha de timing nao deveria ter erro relevante
        if r["fault_type"] in TIMING_FAULTS and r["error_rate_pct"] > 0.1:
            reasons.append(f"erro_em_timing_fault({r['error_rate_pct']:.2f}%)")
        # ONE/QUORUM nao deveriam ter erro relevante em nenhuma falha
        if r["consistency"] in ("ONE", "QUORUM") and r["error_rate_pct"] > 1.0:
            reasons.append(f"erro_alto_em_{r['consistency']}({r['error_rate_pct']:.2f}%)")
        if reasons:
            flags.append({
                "run_id": r["run_id"], "fault_type": r["fault_type"],
                "consistency": r["consistency"], "threads": r["threads"], "rep": r["rep"],
                "error_rate_pct": round(r["error_rate_pct"], 2),
                "thr_pre_ops": round(r["thr_pre_fault_ops"], 1) if pd.notna(r["thr_pre_fault_ops"]) else None,
                "reasons": "; ".join(reasons),
            })
    return pd.DataFrame(flags)


def flag_high_cv(d: pd.DataFrame, threshold_pct: float = 20.0) -> pd.DataFrame:
    """Células cuja métrica principal varia muito entre reps (instabilidade)."""
    rows = []
    for (ft, cons, thr), g in d.groupby(["fault_type", "consistency", "threads"]):
        if len(g) < 2:
            continue
        if ft in ERROR_FAULTS:
            col, label = "error_rate_pct", "erro"
        else:
            col, label = "degradation_pct", "degradacao"
        c = cv(g[col])
        if c > threshold_pct:
            rows.append({
                "fault_type": ft, "consistency": cons, "threads": thr,
                "metric": label, "cv_pct": round(c, 1),
                "values": [round(v, 2) for v in g[col].tolist()],
            })
    return pd.DataFrame(rows)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default="all_runs.csv")
    ap.add_argument("--out-dir", default="analysis")
    ap.add_argument("--cv-threshold", type=float, default=20.0)
    args = ap.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    d = load(Path(args.csv))
    print(f"Carregados {len(d)} runs de fault.\n")

    # ---- tabelas principais ----
    t_err = table_error_faults(d)
    t_tim = table_timing_faults(d)
    mat = summary_matrix(d)
    suspect = flag_suspect_runs(d)
    high_cv = flag_high_cv(d, args.cv_threshold)

    t_err.to_csv(out_dir / "table_error_faults.csv", index=False)
    t_tim.to_csv(out_dir / "table_timing_faults.csv", index=False)
    mat.to_csv(out_dir / "summary_matrix.csv", index=False)
    if not suspect.empty:
        suspect.to_csv(out_dir / "suspect_runs.csv", index=False)
    if not high_cv.empty:
        high_cv.to_csv(out_dir / "high_cv_cells.csv", index=False)

    # ---- impressão legível ----
    pd.options.display.width = 200
    pd.options.display.max_columns = 99

    print("=" * 78)
    print("CRASH & PARTITION — taxa de erro e MTTR (métrica: disponibilidade)")
    print("=" * 78)
    print(t_err.to_string(index=False))

    print("\n" + "=" * 78)
    print("DELAY & LOSS — degradação de throughput (métrica: performability)")
    print("=" * 78)
    print(t_tim.to_string(index=False))

    print("\n" + "=" * 78)
    print("MATRIZ RESUMO (falha × consistência, média sobre threads/reps)")
    print("=" * 78)
    pm = mat.pivot(index="fault_type", columns="consistency", values="value")
    pm = pm.reindex(columns=CONS_ORDER)
    print(pm.to_string())

    print("\n" + "=" * 78)
    print(f"RUNS SUSPEITOS ({len(suspect)})")
    print("=" * 78)
    if suspect.empty:
        print("nenhum")
    else:
        print(suspect.to_string(index=False))

    print("\n" + "=" * 78)
    print(f"CÉLULAS COM CV ALTO entre reps (> {args.cv_threshold}%) ({len(high_cv)})")
    print("=" * 78)
    if high_cv.empty:
        print("nenhuma")
    else:
        print(high_cv.to_string(index=False))

    print(f"\nTabelas salvas em {out_dir}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())