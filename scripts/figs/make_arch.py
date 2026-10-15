#!/usr/bin/env python3
"""
make_arch.py — gera a Figura 2 do artigo (arquitetura do ambiente experimental)
em PT ou EN, com matplotlib.

Reproduz o conteúdo da arch_pt.pdf original: cliente de carga YCSB (e2-medium)
ligado por rede interna ao cluster Cassandra 4.1 de cinco nós e2-standard-2
(RF=3, SimpleStrategy, 256 vnodes/nó), tudo na zona us-central1-a do GCP.

Uso:
    python make_arch.py --lang pt --out arch_pt.pdf
    python make_arch.py --lang en --out arch_en.pdf
"""
from __future__ import annotations
import argparse
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch

LABELS = {
    "pt": {
        "gcp": "Google Cloud Platform — zona us-central1-a",
        "client": "Cliente de carga",
        "client_sub": "YCSB 0.17.0 · e2-medium",
        "net": "rede interna (~0,3 ms)",
        "cluster": "Cluster Cassandra 4.1 · RF = 3 · SimpleStrategy",
        "node": "nó-{i}",
        "ring": "anel de tokens (256 vnodes/nó) · gossip",
        "foot": "Workload A · 100k registros · CL ∈ {ONE, QUORUM, ALL}",
    },
    "en": {
        "gcp": "Google Cloud Platform — zone us-central1-a",
        "client": "Load client",
        "client_sub": "YCSB 0.17.0 · e2-medium",
        "net": "internal network (~0.3 ms)",
        "cluster": "Cassandra 4.1 cluster · RF = 3 · SimpleStrategy",
        "node": "node-{i}",
        "ring": "token ring (256 vnodes/node) · gossip",
        "foot": "Workload A · 100k records · CL ∈ {ONE, QUORUM, ALL}",
    },
}

NAVY = "#1f2a5c"
BLUE = "#3a5fa8"
LIGHT = "#eef2fb"
LIGHTER = "#f7f9fe"
BORDER = "#9db0d9"
GREY = "#555555"
IPS = ["10.128.0.2", "10.128.0.3", "10.128.0.4", "10.128.0.5", "10.128.0.6"]


def box(ax, x, y, w, h, fc, ec, lw=1.0, r=0.03, ls="-"):
    p = FancyBboxPatch((x, y), w, h, boxstyle=f"round,pad=0,rounding_size={r}",
                       facecolor=fc, edgecolor=ec, lw=lw, ls=ls)
    ax.add_patch(p)
    return p


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang", choices=["pt", "en"], default="pt")
    ap.add_argument("--out", default="arch.pdf")
    args = ap.parse_args()
    L = LABELS[args.lang]

    fig, ax = plt.subplots(figsize=(8.9, 4.7))
    ax.set_xlim(0, 10)
    ax.set_ylim(0, 5.3)
    ax.axis("off")

    # caixa externa: GCP
    box(ax, 0.2, 0.55, 9.6, 4.55, LIGHTER, BORDER, lw=1.2, r=0.15, ls="--")
    ax.text(0.45, 4.85, L["gcp"], ha="left", va="center", fontsize=10.5,
            fontweight="bold", color=NAVY)

    # cliente de carga
    cx, cy, cw, ch = 3.3, 3.85, 3.4, 0.8
    box(ax, cx, cy, cw, ch, NAVY, NAVY, r=0.1)
    ax.text(cx + cw / 2, cy + ch * 0.66, L["client"], ha="center", va="center",
            fontsize=10.5, fontweight="bold", color="white")
    ax.text(cx + cw / 2, cy + ch * 0.27, L["client_sub"], ha="center", va="center",
            fontsize=9, color="#dfe6f7")

    # seta bidirecional cliente <-> cluster, com rótulo da rede
    ax.annotate("", xy=(5.0, 3.1), xytext=(5.0, cy),
                arrowprops=dict(arrowstyle="<->", color=BLUE, lw=1.6))
    box(ax, 3.95, 3.3, 2.1, 0.32, "white", BORDER, r=0.06)
    ax.text(5.0, 3.46, L["net"], ha="center", va="center", fontsize=8.5,
            fontweight="bold", color=NAVY)

    # cluster
    kx, ky, kw, kh = 0.5, 0.85, 9.0, 2.25
    box(ax, kx, ky, kw, kh, LIGHT, BORDER, lw=1.2, r=0.12)
    ax.text(kx + 0.25, ky + kh - 0.25, L["cluster"], ha="left", va="center",
            fontsize=10, fontweight="bold", color=NAVY)

    # nós
    n = 5
    nw, nh, gap = 1.3, 1.0, (kw - 0.6 - n * 1.3) / (n - 1)
    ny = ky + 0.7
    xs = []
    for i in range(n):
        nx = kx + 0.3 + i * (nw + gap)
        xs.append(nx + nw / 2)
        box(ax, nx, ny, nw, nh, "white", BORDER, lw=1.0, r=0.08)
        ax.text(nx + nw / 2, ny + nh * 0.74, L["node"].format(i=i + 1),
                ha="center", va="center", fontsize=10, fontweight="bold", color=NAVY)
        ax.text(nx + nw / 2, ny + nh * 0.46, "e2-standard-2", ha="center",
                va="center", fontsize=8.2, color=GREY)
        ax.text(nx + nw / 2, ny + nh * 0.2, IPS[i], ha="center", va="center",
                fontsize=8.2, fontweight="bold", color=BLUE)

    # anel de tokens: linha ligando os nós, com pontos
    ry = ny - 0.22
    ax.plot([xs[0], xs[-1]], [ry, ry], color=BLUE, lw=1.1, zorder=1)
    for x in xs:
        ax.plot([x, x], [ny, ry], color=BLUE, lw=0.9, zorder=1)
        ax.plot(x, ry, "o", ms=4.5, color=BLUE, zorder=2)
    ax.text((xs[0] + xs[-1]) / 2, ry - 0.2, L["ring"], ha="center", va="center",
            fontsize=8.5, style="italic", color=GREY)

    # rodapé
    ax.text(5.0, 0.25, L["foot"], ha="center", va="center", fontsize=9, color=GREY)

    out = Path(args.out)
    fig.savefig(out, bbox_inches="tight")
    fig.savefig(out.with_suffix(".png"), dpi=130, bbox_inches="tight")
    print(f"arquitetura gerada: {out} (+ .png)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
