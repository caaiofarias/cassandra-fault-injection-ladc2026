#!/usr/bin/env python3
"""
make_timeline.py — gera a Figura 1 do artigo (linha do tempo de uma execução
de injeção de faltas) em PT ou EN.

Reproduz a fig_timeline_pt.pdf original (matplotlib): três faixas coloridas
(pré-falta / falta ativa / recuperação), setas de injeção e remoção da falta e a
anotação da janela de 90 s.

Uso:
    python make_timeline.py --lang pt --out fig_timeline_pt.pdf
    python make_timeline.py --lang en --out fig_timeline_en.pdf
"""
from __future__ import annotations
import argparse
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

LABELS = {
    "pt": {
        "pre": "Pré-falta\n(saudável)",
        "fault": "Falta ativa",
        "rec": "Recuperação",
        "inject": "Injeção da falta",
        "remove": "Remoção da falta",
        "x": "Tempo de execução (s)",
        "window": "janela de falta = 90 s",
    },
    "en": {
        "pre": "Pre-fault\n(healthy)",
        "fault": "Active fault",
        "rec": "Recovery",
        "inject": "Fault injection",
        "remove": "Fault removal",
        "x": "Run time (s)",
        "window": "fault window = 90 s",
    },
}

T_INJ, T_REM, T_END = 60, 150, 300
RED, GREEN = "#d62728", "#2ca02c"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang", choices=["pt", "en"], default="pt")
    ap.add_argument("--out", default="fig_timeline.pdf")
    args = ap.parse_args()
    L = LABELS[args.lang]

    fig, ax = plt.subplots(figsize=(8.9, 2.5))
    y0, h = 0.0, 1.0
    bands = [
        (0, T_INJ, "#c8e6c9", L["pre"]),
        (T_INJ, T_REM, "#f4b6b6", L["fault"]),
        (T_REM, T_END, "#c9dcf5", L["rec"]),
    ]
    for x0, x1, color, label in bands:
        ax.add_patch(Rectangle((x0, y0), x1 - x0, h, facecolor=color,
                               edgecolor="black", lw=1.0))
        ax.text((x0 + x1) / 2, y0 + h / 2, label, ha="center", va="center",
                fontsize=10, fontweight="bold")

    # marcadores de injeção / remoção
    for t, color, label in ((T_INJ, RED, L["inject"]), (T_REM, GREEN, L["remove"])):
        # linha tracejada apenas dentro da faixa (não atravessa os rótulos)
        ax.plot([t, t], [y0, y0 + h], color=color, ls="--", lw=1.2, zorder=3)
        ax.annotate(label, xy=(t, y0 + h + 0.02), xytext=(t, y0 + h + 0.45),
                    ha="center", va="bottom", fontsize=9.5, fontweight="bold",
                    color=color,
                    arrowprops=dict(arrowstyle="->", color=color, lw=1.2))
        ax.text(t - 2.5, y0 + 0.07, f"t={t}s", ha="right", va="bottom",
                fontsize=8.5, color=color)

    # anotação da janela de falta (abaixo do eixo, à esquerda do rótulo do eixo)
    ax.annotate("", xy=(T_INJ, y0 - 0.2), xytext=(T_REM, y0 - 0.2),
                arrowprops=dict(arrowstyle="<->", color=RED, lw=1.0))
    ax.text((T_INJ + T_REM) / 2, y0 - 0.27, L["window"], ha="center", va="top",
            fontsize=8.5, color=RED)

    ax.set_xlim(-2, T_END + 2)
    ax.set_ylim(y0 - 0.75, y0 + h + 0.95)
    ax.set_xticks([0, T_INJ, T_REM, T_END])
    ax.set_yticks([])
    ax.text(225, y0 - 0.27, L["x"], ha="center", va="top", fontsize=9.5)
    for spine in ("left", "right", "top"):
        ax.spines[spine].set_visible(False)
    ax.spines["bottom"].set_position(("data", y0))
    ax.tick_params(axis="x", labelsize=9)

    out = Path(args.out)
    fig.savefig(out, bbox_inches="tight")
    fig.savefig(out.with_suffix(".png"), dpi=130, bbox_inches="tight")
    print(f"timeline gerada: {out} (+ .png)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
