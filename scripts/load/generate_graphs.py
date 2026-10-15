#!/usr/bin/env python3
"""
plot_baseline.py -- gera graficos de baseline do experimento Cassandra.

Uso:
    python plot_baseline.py                        # le data/processed/all_runs.csv
    python plot_baseline.py --csv outro.csv        # csv customizado
    python plot_baseline.py --out figs/            # diretorio de saida
    python plot_baseline.py --fmt pdf              # pdf | png | both (default: both)

Dependencias:
    pip install pandas matplotlib
"""
import argparse
import sys
from pathlib import Path

import pandas as pd
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

# ── paleta e marcadores ──────────────────────────────────────────────────────
CL_ORDER = ['ONE', 'QUORUM', 'ALL']
COLORS   = {'ONE': '#1a6faf', 'QUORUM': '#e07b00', 'ALL': '#b01c1c'}
MARKERS  = {'ONE': 'o',       'QUORUM': 's',        'ALL': '^'}
THREADS  = [10, 30, 50]

# ── estilo artigo cientifico (Springer LNCS compativel) ──────────────────────
plt.rcParams.update({
    'font.family':      'serif',
    'font.size':        9,
    'axes.titlesize':   9,
    'axes.labelsize':   9,
    'xtick.labelsize':  8,
    'ytick.labelsize':  8,
    'legend.fontsize':  8,
    'axes.linewidth':   0.8,
    'grid.linewidth':   0.5,
    'lines.linewidth':  1.5,
    'lines.markersize': 5,
    'figure.dpi':       150,
    'savefig.dpi':      300,
    'savefig.bbox':     'tight',
})


def load_and_aggregate(csv_path: Path) -> pd.DataFrame:
    df = pd.read_csv(csv_path)

    # filtra so baseline (ignora fases de falha se ja existirem no csv)
    df = df[df['phase'] == 'baseline'].copy()

    if df.empty:
        print(f"[erro] nenhuma linha com phase=baseline em {csv_path}", file=sys.stderr)
        sys.exit(1)

    missing = [c for c in CL_ORDER if c not in df['consistency'].unique()]
    if missing:
        print(f"[aviso] consistencias ausentes no CSV: {missing}", file=sys.stderr)

    g = df.groupby(['consistency', 'threads']).agg(
        thr_mean=('throughput_ops', 'mean'), thr_std=('throughput_ops', 'std'),
        read_mean=('read_avg_ms',   'mean'), read_std=('read_avg_ms',   'std'),
        read_p99_mean=('read_p99_ms', 'mean'), read_p99_std=('read_p99_ms', 'std'),
        upd_mean=('update_avg_ms',  'mean'), upd_std=('update_avg_ms',  'std'),
    ).reset_index()

    return g


def get_series(g: pd.DataFrame, cons: str, col_mean: str, col_std: str):
    rows = g[g['consistency'] == cons].sort_values('threads')
    return rows[col_mean].values, rows[col_std].values


def add_panel(ax, g, col_mean, col_std, ylabel, title):
    for cons in CL_ORDER:
        if cons not in g['consistency'].values:
            continue
        m, s = get_series(g, cons, col_mean, col_std)
        threads = g[g['consistency'] == cons].sort_values('threads')['threads'].values
        ax.errorbar(threads, m, yerr=s, label=cons,
                    color=COLORS[cons], marker=MARKERS[cons],
                    capsize=3, capthick=0.8, elinewidth=0.8)
    ax.set_xlabel('Threads')
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.set_xticks(THREADS)
    ax.grid(True, linestyle='--', alpha=0.5)
    ax.legend(title='Consistency')
    ax.set_ylim(bottom=0)


def save(fig, out_dir: Path, name: str, fmt: str):
    if fmt in ('png', 'both'):
        fig.savefig(out_dir / f'{name}.png')
        print(f'  -> {out_dir / name}.png')
    if fmt in ('pdf', 'both'):
        fig.savefig(out_dir / f'{name}.pdf')
        print(f'  -> {out_dir / name}.pdf')


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--csv', default='data/processed/all_runs.csv',
                    help='caminho para o all_runs.csv (default: data/processed/all_runs.csv)')
    ap.add_argument('--out', default='figs',
                    help='diretorio de saida (default: figs/)')
    ap.add_argument('--fmt', choices=['png', 'pdf', 'both'], default='both',
                    help='formato de saida (default: both)')
    args = ap.parse_args()

    csv_path = Path(args.csv)
    out_dir  = Path(args.out)

    if not csv_path.exists():
        print(f'[erro] arquivo nao encontrado: {csv_path}', file=sys.stderr)
        sys.exit(1)

    out_dir.mkdir(parents=True, exist_ok=True)

    print(f'[lendo] {csv_path}')
    g = load_and_aggregate(csv_path)

    suptitle = 'Workload A — Baseline (RF=3, 100k records, 50k ops)'

    # ── Fig 1: Throughput + READ avg latency ─────────────────────────────────
    print('[gerando] fig1_throughput_latency')
    fig1, (ax1, ax2) = plt.subplots(1, 2, figsize=(6.5, 2.8))
    add_panel(ax1, g, 'thr_mean',  'thr_std',  'Throughput (ops/s)',   '(a) Throughput')
    add_panel(ax2, g, 'read_mean', 'read_std', 'Average Latency (ms)', '(b) READ Average Latency')
    fig1.suptitle(suptitle, fontsize=9, y=1.01)
    fig1.tight_layout()
    save(fig1, out_dir, 'fig1_throughput_latency', args.fmt)
    plt.close(fig1)

    # ── Fig 2: READ P99 + UPDATE avg latency ─────────────────────────────────
    print('[gerando] fig2_p99_update')
    fig2, (ax3, ax4) = plt.subplots(1, 2, figsize=(6.5, 2.8))
    add_panel(ax3, g, 'read_p99_mean', 'read_p99_std', 'P99 Latency (ms)',     '(c) READ P99 Latency')
    add_panel(ax4, g, 'upd_mean',      'upd_std',      'Average Latency (ms)', '(d) UPDATE Average Latency')
    fig2.suptitle(suptitle, fontsize=9, y=1.01)
    fig2.tight_layout()
    save(fig2, out_dir, 'fig2_p99_update', args.fmt)
    plt.close(fig2)

    print('[ok] graficos gerados em', out_dir)


if __name__ == '__main__':
    main()