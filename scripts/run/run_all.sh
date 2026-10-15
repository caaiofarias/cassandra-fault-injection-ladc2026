#!/usr/bin/env bash
# run_all.sh — orquestra a bateria completa de cenarios chamando run_bench.sh.
#
# Roda a grade cartesiana: consistencias x threads x repeticoes.
# Para Fase 2, tambem varre tipos de falha.
#
# Caracteristicas:
#   - warm-up descartado antes da primeira rep de cada cell (reduz JIT/JVM noise)
#   - sleep entre runs configuravel (padrao 60s para compaction estabilizar)
#   - load uma vez por bateria
#   - resume: dentro de uma bateria, pula celulas ja concluidas
#   - baterias sao isoladas por --batch N
#
# Uso:
#   HOSTS="..." ./run_all.sh --phase baseline --reps 3 --batch 1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_BENCH="${SCRIPT_DIR}/run_bench.sh"
ROOT="${BENCH_ROOT:-$(pwd)}"

# ---------- defaults ----------
CONSISTENCIES=(ONE QUORUM ALL)
THREADS_LIST=(10 30 50)
FAULTS=(node_crash coord_crash latency packet_loss partition)
REPS=3
PHASE="baseline"
BATCH=1
FAULT_START=60
FAULT_DUR=60
MAXEXEC=300
DRY_RUN=0
RESUME=1
INTER_RUN_SLEEP=60        # 60s entre runs (compaction)
WARMUP=1                  # 1 = warm-up descartado por cell
WARMUP_OPS=10000          # operations no warm-up

usage() {
  cat <<USAGE
Uso: HOSTS="ip1,ip2,..." $0 [opcoes]
  --phase baseline|fault   (default: baseline)
  --reps N                 repeticoes por celula (default: 3)
  --batch N                identificador da bateria (default: 1)
  --consistencies "A B C"  (default: ONE QUORUM ALL)
  --threads "10 50 100"    (default: 10 50 100)
  --faults "f1 f2"         tipos de falha p/ phase=fault
  --no-resume              re-roda mesmo celulas ja feitas nesta bateria
  --sleep S                pausa entre runs em s (default: 60)
  --no-warmup              desabilita warm-up por cell
  --warmup-ops N           operations no warm-up (default: 10000)
  --dry-run                so mostra o plano
USAGE
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)         PHASE="$2"; shift 2 ;;
    --reps)          REPS="$2"; shift 2 ;;
    --batch)         BATCH="$2"; shift 2 ;;
    --consistencies) read -r -a CONSISTENCIES <<< "$2"; shift 2 ;;
    --threads)       read -r -a THREADS_LIST <<< "$2"; shift 2 ;;
    --faults)        read -r -a FAULTS <<< "$2"; shift 2 ;;
    --no-resume)     RESUME=0; shift ;;
    --sleep)         INTER_RUN_SLEEP="$2"; shift 2 ;;
    --no-warmup)     WARMUP=0; shift ;;
    --warmup-ops)    WARMUP_OPS="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       usage ;;
    *) echo "opcao desconhecida: $1" >&2; usage ;;
  esac
done

META_DIR="${ROOT}/data/raw/meta"
ORCH_DIR="${ROOT}/data/raw/orchestrator"
mkdir -p "$META_DIR" "$ORCH_DIR"
SESSION_TS="$(date -u +%Y%m%dT%H%M%S)"
ORCH_LOG="${ORCH_DIR}/session_${SESSION_TS}.log"

log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$ORCH_LOG"; }

cell_done() {
  local phase="$1" cons="$2" thr="$3" rep="$4"
  local pattern="${phase}_${cons}_t${thr}_rep${rep}_b${BATCH}_*.json"
  compgen -G "${META_DIR}/${pattern}" > /dev/null 2>&1
}

# checa se ja existe pelo menos UMA rep desta cell (pra saber se precisa de warm-up)
any_rep_done() {
  local phase="$1" cons="$2" thr="$3"
  local pattern="${phase}_${cons}_t${thr}_rep*_b${BATCH}_*.json"
  compgen -G "${META_DIR}/${pattern}" > /dev/null 2>&1
}

# faz um warm-up descartado: roda run com poucas ops e remove os 3 arquivos
run_warmup() {
  local phase="$1" cons="$2" thr="$3"
  log "      [warm-up] $cons/t$thr ($WARMUP_OPS ops, descartado)"
  if [[ "$DRY_RUN" -eq 1 ]]; then return 0; fi
  # roda warm-up com rep=0 e operations reduzidos
  if HOSTS="${HOSTS:-}" BENCH_ROOT="$ROOT" BATCH="${BATCH}_warmup" \
     bash "$RUN_BENCH" -p "$phase" -c "$cons" -t "$thr" -r 0 \
                       -o "$WARMUP_OPS" -L >> "$ORCH_LOG" 2>&1; then
    # remove os arquivos do warm-up
    local pattern="${phase}_${cons}_t${thr}_rep0_b${BATCH}_warmup_*"
    rm -f "$META_DIR"/${pattern}.json
    rm -f "${ROOT}/data/raw/load"/${pattern}.log
    rm -f "${ROOT}/data/raw/workload"/${pattern}.log
    log "      [warm-up] OK (descartado)"
  else
    log "      [warm-up] FALHOU — continuando mesmo assim"
  fi
}

# monta lista de jobs
declare -a JOBS
declare -a JOB_DESC
declare -a JOB_CELL    # "cons|threads" para detectar troca de cell

if [[ "$PHASE" == "baseline" ]]; then
  for c in "${CONSISTENCIES[@]}"; do
    for t in "${THREADS_LIST[@]}"; do
      for ((r=1; r<=REPS; r++)); do
        JOBS+=("-p baseline -c $c -t $t -r $r")
        JOB_DESC+=("baseline|$c|t$t|rep$r|b$BATCH")
        JOB_CELL+=("$c|$t")
      done
    done
  done
elif [[ "$PHASE" == "fault" ]]; then
  for f in "${FAULTS[@]}"; do
    for c in "${CONSISTENCIES[@]}"; do
      for t in "${THREADS_LIST[@]}"; do
        for ((r=1; r<=REPS; r++)); do
          JOBS+=("-F $f -c $c -t $t -r $r -S $FAULT_START -D $FAULT_DUR -m $MAXEXEC")
          JOB_DESC+=("fault:$f|$c|t$t|rep$r|b$BATCH")
          JOB_CELL+=("$f|$c|$t")
        done
      done
    done
  done
else
  echo "phase invalida: $PHASE" >&2; exit 1
fi

TOTAL=${#JOBS[@]}
log "=== Sessao $SESSION_TS | phase=$PHASE | batch=$BATCH | reps=$REPS | $TOTAL jobs ==="
log "warmup=$WARMUP warmup_ops=$WARMUP_OPS sleep_between_runs=${INTER_RUN_SLEEP}s"
log "HOSTS=${HOSTS:-<nao definido!>}"
[[ -z "${HOSTS:-}" && "$DRY_RUN" -eq 0 ]] && { echo "ERRO: defina HOSTS=..." >&2; exit 1; }

FIRST_LOAD_DONE=0
idx=0
skipped=0
failed=0
LAST_CELL=""

for i in "${!JOBS[@]}"; do
  idx=$((idx+1))
  job="${JOBS[$i]}"
  desc="${JOB_DESC[$i]}"
  cell="${JOB_CELL[$i]}"

  c=$(grep -oP '(?<=-c )\S+' <<< "$job")
  t=$(grep -oP '(?<=-t )\S+' <<< "$job")
  r=$(grep -oP '(?<=-r )\S+' <<< "$job")

  if [[ "$RESUME" -eq 1 ]] && cell_done "$PHASE" "$c" "$t" "$r"; then
    log "[$idx/$TOTAL] PULADO (ja existe nesta bateria): $desc"
    skipped=$((skipped+1))
    LAST_CELL="$cell"
    continue
  fi

  # warm-up: roda quando trocamos de cell E nao tem ainda nenhuma rep daquela cell
  if [[ "$WARMUP" -eq 1 && "$cell" != "$LAST_CELL" ]]; then
    if ! any_rep_done "$PHASE" "$c" "$t"; then
      run_warmup "$PHASE" "$c" "$t"
      # so faz warm-up uma vez por cell, mesmo se cell tiver multiplas reps
    fi
  fi
  LAST_CELL="$cell"

  load_flag="-L"
  if [[ "$PHASE" == "baseline" && "$FIRST_LOAD_DONE" -eq 0 ]]; then
    load_flag=""
  fi

  log "[$idx/$TOTAL] >>> $desc"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    continue
  fi

  if HOSTS="${HOSTS:-}" BENCH_ROOT="$ROOT" BATCH="$BATCH" \
     bash "$RUN_BENCH" $job $load_flag >> "$ORCH_LOG" 2>&1; then
    [[ -z "$load_flag" ]] && FIRST_LOAD_DONE=1
    log "      OK: $desc"
  else
    rc=$?
    log "      FALHOU (rc=$rc): $desc"
    failed=$((failed+1))
  fi

  if (( idx < TOTAL )); then
    sleep "$INTER_RUN_SLEEP"
  fi
done

log "=== Fim. total=$TOTAL ok=$((TOTAL-skipped-failed)) pulados=$skipped falhas=$failed ==="
if [[ "$DRY_RUN" -eq 0 ]]; then
  log "Parseando resultados..."
  python "${SCRIPT_DIR}/parser.py" --root "$ROOT" >> "$ORCH_LOG" 2>&1 || \
    python "${SCRIPT_DIR}/parse_runs.py" --root "$ROOT" >> "$ORCH_LOG" 2>&1 || true
  log "Pronto. Veja data/processed/all_runs.csv e o log: $ORCH_LOG"
fi
