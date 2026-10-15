#!/usr/bin/env bash
# run_bench.sh — dispara UMA execucao YCSB (load + run) e salva logs + metadados.
#
# Uso:
#   ./run_bench.sh -c ONE -t 50 -r 2 [opcoes de falha]
#
# Gera run_id no formato: <phase>_<consistency>_t<threads>_rep<rep>_<UTC timestamp>
# e grava:
#   data/raw/load/<run_id>.log
#   data/raw/workload/<run_id>.log
#   data/raw/meta/<run_id>.json
#
# Pre-requisito: YCSB instalado. Ajuste YCSB_DIR se necessario.
set -euo pipefail

# ---------- defaults (edite conforme seu ambiente) ----------
PHASE="baseline"
CONSISTENCY="ONE"
THREADS=50
REP=1
RECORDS=100000
OPERATIONS=50000
WORKLOAD="workloada"
RF=3
ENV="${ENV:-localhost}"
CASSANDRA_VERSION="${CASSANDRA_VERSION:-4.1}"
CLUSTER_NODES="${CLUSTER_NODES:-1}"
HOSTS="${HOSTS:-localhost}"
# campos de falha (Fase 2) - ficam null no baseline
FAULT_TYPE="none"
FAULT_START_OFFSET_S=""
FAULT_DURATION_S=""
NOTES=""
# extras
MAXEXECTIME=""           # ex: 300 (segundos); vazio = roda ate esgotar operations
SKIP_LOAD=0              # 1 = pula a fase de load (reutiliza dados ja carregados)

# raizes
ROOT="${BENCH_ROOT:-$(pwd)}"
YCSB_DIR="${YCSB_DIR:-$HOME/ycsb-0.17.0}"
YCSB="${YCSB_DIR}/bin/ycsb.sh"
WORKLOAD_FILE="${WORKLOAD_FILE:-${YCSB_DIR}/workloads/${WORKLOAD}}"

usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -n 20
  exit 1
}

while getopts "p:c:t:r:n:o:w:F:S:D:H:N:m:Lh" opt; do
  case "$opt" in
    p) PHASE="$OPTARG" ;;
    c) CONSISTENCY="$OPTARG" ;;
    t) THREADS="$OPTARG" ;;
    r) REP="$OPTARG" ;;
    n) RECORDS="$OPTARG" ;;
    o) OPERATIONS="$OPTARG" ;;
    w) WORKLOAD="$OPTARG"; WORKLOAD_FILE="${YCSB_DIR}/workloads/${OPTARG}" ;;
    F) FAULT_TYPE="$OPTARG"; PHASE="fault" ;;
    S) FAULT_START_OFFSET_S="$OPTARG" ;;
    D) FAULT_DURATION_S="$OPTARG" ;;
    H) HOSTS="$OPTARG" ;;
    N) NOTES="$OPTARG" ;;
    m) MAXEXECTIME="$OPTARG" ;;
    L) SKIP_LOAD=1 ;;
    h|*) usage ;;
  esac
done

# ---------- monta run_id ----------
TS="$(date -u +%Y%m%dT%H%M%S)"
RUN_ID="${PHASE}_${CONSISTENCY}_t${THREADS}_rep${REP}_${TS}"

RAW_LOAD="${ROOT}/data/raw/load"
RAW_WL="${ROOT}/data/raw/workload"
RAW_META="${ROOT}/data/raw/meta"
mkdir -p "$RAW_LOAD" "$RAW_WL" "$RAW_META"

LOAD_LOG="${RAW_LOAD}/${RUN_ID}.log"
WL_LOG="${RAW_WL}/${RUN_ID}.log"
META="${RAW_META}/${RUN_ID}.json"

# propriedades comuns do driver Cassandra
CQL_PROPS=(-p recordcount="$RECORDS" -p operationcount="$OPERATIONS" -p hosts="$HOSTS")
[[ -n "$MAXEXECTIME" ]] && CQL_PROPS+=(-p maxexecutiontime="$MAXEXECTIME")

echo ">>> RUN_ID=$RUN_ID"
echo ">>> phase=$PHASE consistency=$CONSISTENCY threads=$THREADS rep=$REP fault=$FAULT_TYPE"

# ---------- LOAD ----------
if [[ "$SKIP_LOAD" -eq 0 ]]; then
  echo ">>> [load] -> $LOAD_LOG"
  "$YCSB" load cassandra-cql -P "$WORKLOAD_FILE" \
    "${CQL_PROPS[@]}" \
    -p cassandra.writeconsistencylevel="$CONSISTENCY" \
    -threads "$THREADS" \
    -s 2>&1 | tee "$LOAD_LOG"
  LOAD_RC=${PIPESTATUS[0]}
  if [[ "$LOAD_RC" -ne 0 ]]; then
    echo ">>> [ERRO] load falhou (rc=$LOAD_RC). Abortando sem gravar meta." >&2
    exit "$LOAD_RC"
  fi
else
  echo ">>> [load] pulado (-L)"
  echo "SKIPPED" > "$LOAD_LOG"
fi

# ---------- RUN (workload) ----------
echo ">>> [run] -> $WL_LOG"
"$YCSB" run cassandra-cql -P "$WORKLOAD_FILE" \
  "${CQL_PROPS[@]}" \
  -p cassandra.readconsistencylevel="$CONSISTENCY" \
  -p cassandra.writeconsistencylevel="$CONSISTENCY" \
  -threads "$THREADS" \
  -s 2>&1 | tee "$WL_LOG"
RUN_RC=${PIPESTATUS[0]}
if [[ "$RUN_RC" -ne 0 ]]; then
  echo ">>> [ERRO] run falhou (rc=$RUN_RC). Abortando sem gravar meta." >&2
  echo ">>> Logs parciais mantidos para inspecao: $WL_LOG" >&2
  exit "$RUN_RC"
fi

# sanidade: workload log precisa ter a linha de throughput
if ! grep -q '^\[OVERALL\], Throughput' "$WL_LOG"; then
  echo ">>> [ERRO] workload log sem [OVERALL] Throughput. Run invalido; meta nao gravado." >&2
  exit 3
fi

# ---------- META ----------
jnull() { [[ -z "$1" ]] && printf 'null' || printf '%s' "$1"; }
jstr()  { [[ -z "$1" ]] && printf 'null' || printf '"%s"' "$1"; }

cat > "$META" <<EOF
{
  "run_id": "${RUN_ID}",
  "timestamp_utc": "${TS}",
  "phase": "${PHASE}",
  "consistency": "${CONSISTENCY}",
  "threads": ${THREADS},
  "rep": ${REP},
  "records": ${RECORDS},
  "operations": ${OPERATIONS},
  "workload": "${WORKLOAD}",
  "rf": ${RF},
  "fault_type": "${FAULT_TYPE}",
  "fault_start_offset_s": $(jnull "$FAULT_START_OFFSET_S"),
  "fault_duration_s": $(jnull "$FAULT_DURATION_S"),
  "cluster_nodes": ${CLUSTER_NODES},
  "cassandra_version": "${CASSANDRA_VERSION}",
  "env": "${ENV}",
  "hosts": $(jstr "$HOSTS"),
  "notes": $(jstr "$NOTES")
}
EOF

echo ">>> meta -> $META"
echo ">>> OK: $RUN_ID"
