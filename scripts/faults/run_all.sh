#!/usr/bin/env bash
# run_all.sh (v2) — orquestra a bateria completa chamando run_bench.sh.
#
# Mudancas v2:
#   - nomes de falha alinhados com fault_inject.sh v2:
#     node_crash, coord_crash, net_delay, net_loss, net_partition
#   - pre-load tambem na phase=fault (1x no inicio da bateria)
#   - sleep default maior para fault (90s)
#
# Uso:
#   HOSTS="..." ./run_all.sh --phase baseline --reps 3 --batch 1
#   HOSTS="..." ./run_all.sh --phase fault --reps 3 --batch 1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_BENCH="${SCRIPT_DIR}/run_bench.sh"
ROOT="${BENCH_ROOT:-$(pwd)}"

# ---------- defaults ----------
CONSISTENCIES=(ONE QUORUM ALL)
THREADS_LIST=(10 30 50)
FAULTS=(node_crash coord_crash net_delay net_loss net_partition)
REPS=3
PHASE="baseline"
BATCH=1
FAULT_START=60
FAULT_DUR=60
MAXEXEC=300
FAULT_OPS=8000000       # operationcount alto na fase fault: garante que o
                        # limitante seja MAXEXEC (tempo), nao a contagem de ops.
                        # pico medido ~18k ops/s; 18k*300s=5.4M, entao 8M da
                        # folga p/ o maxexecutiontime cortar antes de esgotar.
DRY_RUN=0
RESUME=1
INTER_RUN_SLEEP=""        # default escolhido por phase mais abaixo
WARMUP=1
WARMUP_OPS=10000

usage() {
  cat <<USAGE
Uso: HOSTS="ip1,ip2,..." $0 [opcoes]
  --phase baseline|fault   (default: baseline)
  --reps N                 repeticoes por celula (default: 3)
  --batch N                identificador da bateria (default: 1)
  --consistencies "A B C"  (default: ONE QUORUM ALL)
  --threads "10 30 50"     (default: 10 30 50)
  --faults "f1 f2"         tipos de falha p/ phase=fault
                           (node_crash coord_crash net_delay net_loss net_partition)
  --fault-start S          offset em s para injetar (default: 60)
  --fault-dur S            duracao da falha em s (default: 60)
  --fault-ops N            operationcount na fase fault (default: 8000000;
                           alto p/ o limitante ser o tempo, nao as ops)
  --maxexec S              maxexecutiontime do YCSB em s (default: 300)
  --no-resume              re-roda mesmo celulas ja feitas nesta bateria
  --sleep S                pausa entre runs em s (default: 60 baseline / 90 fault)
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
    --fault-start)   FAULT_START="$2"; shift 2 ;;
    --fault-dur)     FAULT_DUR="$2"; shift 2 ;;
    --fault-ops)     FAULT_OPS="$2"; shift 2 ;;
    --maxexec)       MAXEXEC="$2"; shift 2 ;;
    --no-resume)     RESUME=0; shift ;;
    --sleep)         INTER_RUN_SLEEP="$2"; shift 2 ;;
    --no-warmup)     WARMUP=0; shift ;;
    --warmup-ops)    WARMUP_OPS="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       usage ;;
    *) echo "opcao desconhecida: $1" >&2; usage ;;
  esac
done

# default de sleep por phase
if [[ -z "$INTER_RUN_SLEEP" ]]; then
  if [[ "$PHASE" == "fault" ]]; then INTER_RUN_SLEEP=90; else INTER_RUN_SLEEP=60; fi
fi

META_DIR="${ROOT}/data/raw/meta"
ORCH_DIR="${ROOT}/data/raw/orchestrator"
mkdir -p "$META_DIR" "$ORCH_DIR"
SESSION_TS="$(date -u +%Y%m%dT%H%M%S)"
ORCH_LOG="${ORCH_DIR}/session_${SESSION_TS}.log"

log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$ORCH_LOG"; }

cell_done() {
  # baseline: pattern <phase>_<cons>_t<thr>_rep<rep>_b<batch>_*.json
  # fault:    pattern fault_<fault>_<cons>_t<thr>_rep<rep>_b<batch>_*.json  (run_id idem)
  local pattern="$1"
  compgen -G "${META_DIR}/${pattern}" > /dev/null 2>&1
}

any_rep_done() {
  local pattern="$1"
  compgen -G "${META_DIR}/${pattern}" > /dev/null 2>&1
}

# warm-up descartado (run_id terminando com _warmup)
run_warmup() {
  local cons="$1" thr="$2"
  log "      [warm-up] $cons/t$thr ($WARMUP_OPS ops, descartado)"
  if [[ "$DRY_RUN" -eq 1 ]]; then return 0; fi
  if HOSTS="${HOSTS:-}" BENCH_ROOT="$ROOT" BATCH="${BATCH}_warmup" \
     bash "$RUN_BENCH" -p baseline -c "$cons" -t "$thr" -r 0 \
                       -o "$WARMUP_OPS" -L >> "$ORCH_LOG" 2>&1; then
    rm -f "$META_DIR"/baseline_"${cons}"_t"${thr}"_rep0_b"${BATCH}"_warmup_*.json
    rm -f "${ROOT}/data/raw/load"/baseline_"${cons}"_t"${thr}"_rep0_b"${BATCH}"_warmup_*.log
    rm -f "${ROOT}/data/raw/workload"/baseline_"${cons}"_t"${thr}"_rep0_b"${BATCH}"_warmup_*.log
    log "      [warm-up] OK (descartado)"
  else
    log "      [warm-up] FALHOU — continuando mesmo assim"
  fi
}

# --------- monta jobs ----------
declare -a JOBS
declare -a JOB_DESC
declare -a JOB_CELL          # chave de cell p/ detectar troca (e disparar warm-up)
declare -a JOB_DONE_PATTERN  # padrao p/ verificar conclusao via meta dir

if [[ "$PHASE" == "baseline" ]]; then
  for c in "${CONSISTENCIES[@]}"; do
    for t in "${THREADS_LIST[@]}"; do
      for ((r=1; r<=REPS; r++)); do
        JOBS+=("-p baseline -c $c -t $t -r $r")
        JOB_DESC+=("baseline|$c|t$t|rep$r|b$BATCH")
        JOB_CELL+=("base|$c|$t")
        JOB_DONE_PATTERN+=("baseline_${c}_t${t}_rep${r}_b${BATCH}_*.json")
      done
    done
  done
elif [[ "$PHASE" == "fault" ]]; then
  for f in "${FAULTS[@]}"; do
    for c in "${CONSISTENCIES[@]}"; do
      for t in "${THREADS_LIST[@]}"; do
        for ((r=1; r<=REPS; r++)); do
          JOBS+=("-F $f -c $c -t $t -r $r -S $FAULT_START -D $FAULT_DUR -m $MAXEXEC -o $FAULT_OPS")
          JOB_DESC+=("fault:$f|$c|t$t|rep$r|b$BATCH")
          JOB_CELL+=("$f|$c|$t")
          JOB_DONE_PATTERN+=("fault_${c}_t${t}_rep${r}_b${BATCH}_*.json")
          # nota: o run_id nao carrega o nome da falha; ela vai no meta. Para
          # discriminar nas verificacoes de resume, inspecionamos o meta.json
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
if [[ "$PHASE" == "fault" ]]; then
  log "fault: start=+${FAULT_START}s dur=${FAULT_DUR}s maxexec=${MAXEXEC}s ops=${FAULT_OPS}"
fi
log "HOSTS=${HOSTS:-<nao definido!>}"
[[ -z "${HOSTS:-}" && "$DRY_RUN" -eq 0 ]] && { echo "ERRO: defina HOSTS=..." >&2; exit 1; }

# para phase=fault, fazemos resume baseado em meta.json com fault_type correto
fault_cell_done() {
  local fault="$1" cons="$2" thr="$3" rep="$4"
  local pat="${META_DIR}/fault_${cons}_t${thr}_rep${rep}_b${BATCH}_*.json"
  for f in $pat; do
    [[ -e "$f" ]] || continue
    if grep -q "\"fault_type\": \"${fault}\"" "$f"; then return 0; fi
  done
  return 1
}

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
  done_pat="${JOB_DONE_PATTERN[$i]}"

  c=$(grep -oP '(?<=-c )\S+' <<< "$job")
  t=$(grep -oP '(?<=-t )\S+' <<< "$job")
  r=$(grep -oP '(?<=-r )\S+' <<< "$job")
  f_in_job=$(grep -oP '(?<=-F )\S+' <<< "$job" || true)

  if [[ "$RESUME" -eq 1 ]]; then
    if [[ "$PHASE" == "baseline" ]] && cell_done "$done_pat"; then
      log "[$idx/$TOTAL] PULADO (ja existe nesta bateria): $desc"
      skipped=$((skipped+1)); LAST_CELL="$cell"; continue
    fi
    if [[ "$PHASE" == "fault" ]] && fault_cell_done "$f_in_job" "$c" "$t" "$r"; then
      log "[$idx/$TOTAL] PULADO (ja existe nesta bateria): $desc"
      skipped=$((skipped+1)); LAST_CELL="$cell"; continue
    fi
  fi

  # warm-up: na troca de cell de baseline (no fault nao faz warm-up)
  if [[ "$WARMUP" -eq 1 && "$PHASE" == "baseline" && "$cell" != "$LAST_CELL" ]]; then
    if ! any_rep_done "baseline_${c}_t${t}_rep*_b${BATCH}_*.json"; then
      run_warmup "$c" "$t"
    fi
  fi
  LAST_CELL="$cell"

  # load: 1x no inicio da bateria (qualquer phase)
  load_flag="-L"
  if [[ "$FIRST_LOAD_DONE" -eq 0 ]]; then
    load_flag=""
  fi

  log "[$idx/$TOTAL] >>> $desc"

  if [[ "$DRY_RUN" -eq 1 ]]; then continue; fi

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
  python "${SCRIPT_DIR}/parser.py" --root "$ROOT" >> "$ORCH_LOG" 2>&1 || true
  log "Pronto. Veja data/processed/all_runs.csv e o log: $ORCH_LOG"
fi