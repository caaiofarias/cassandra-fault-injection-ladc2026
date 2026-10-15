#!/usr/bin/env bash
# run_bench.sh (v2) — dispara UMA execucao YCSB (load + run) e salva logs + metadados.
#
# Suporta injecao de falha em background via fault_inject.sh (Fase 2).
#
# Uso:
#   ./run_bench.sh -c ONE -t 50 -r 2                       # baseline
#   ./run_bench.sh -F node_crash -c ONE -t 50 -r 1 -L      # fault, sem reload
#
# Gera run_id: <phase>_<consistency>_t<threads>_rep<rep>_b<batch>_<UTC timestamp>
# Grava:
#   data/raw/load/<run_id>.log
#   data/raw/workload/<run_id>.log
#   data/raw/meta/<run_id>.json
#   data/raw/fault/<run_id>.json     (apenas se phase=fault)
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
ENV="${ENV:-gcp}"
CASSANDRA_VERSION="${CASSANDRA_VERSION:-4.1}"
CLUSTER_NODES="${CLUSTER_NODES:-5}"
HOSTS="${HOSTS:-localhost}"
BATCH="${BATCH:-1}"

# campos de falha (Fase 2) — ficam null no baseline
FAULT_TYPE="none"
FAULT_START_OFFSET_S=""
FAULT_DURATION_S=""
NOTES=""

# extras
MAXEXECTIME=""           # ex: 300 (s); vazio = roda ate esgotar operations
SKIP_LOAD=0              # 1 = pula a fase de load (reutiliza dados ja carregados)

# raizes
ROOT="${BENCH_ROOT:-$(pwd)}"
YCSB_DIR="${YCSB_DIR:-$HOME/ycsb-0.17.0}"
YCSB="${YCSB_DIR}/bin/ycsb.sh"
WORKLOAD_FILE="${WORKLOAD_FILE:-${YCSB_DIR}/workloads/${WORKLOAD}}"
FAULT_INJECT="${FAULT_INJECT:-${ROOT}/scripts/fault_inject.sh}"

usage() {
  cat <<USAGE
Uso: $0 [opcoes]
  -p PHASE           baseline|fault (auto: 'fault' se -F informado)
  -c CONSISTENCY     ONE|QUORUM|ALL
  -t THREADS         numero de threads YCSB
  -r REP             numero da repeticao
  -n RECORDS         recordcount (default $RECORDS)
  -o OPERATIONS      operationcount (default $OPERATIONS)
  -w WORKLOAD        nome do workload (default $WORKLOAD)
  -F FAULT_TYPE      node_crash|coord_crash|net_delay|net_loss|net_partition
  -S OFFSET_S        segundos apos inicio do run para injetar falha (default 60)
  -D DURATION_S      duracao da falha em segundos (default 60)
  -H HOSTS           lista de IPs separados por virgula (ou \$HOSTS)
  -N NOTES           string livre p/ campo notes
  -m MAXEXEC         maxexecutiontime do YCSB em segundos (default 300 em fault)
  -L                 pula a fase de load
  -h                 ajuda
USAGE
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

# defaults derivados para fault phase
if [[ "$PHASE" == "fault" ]]; then
  : "${FAULT_START_OFFSET_S:=60}"
  : "${FAULT_DURATION_S:=60}"
  : "${MAXEXECTIME:=300}"
fi

# ---------- monta run_id ----------
TS="$(date -u +%Y%m%dT%H%M%S)"
RUN_ID="${PHASE}_${CONSISTENCY}_t${THREADS}_rep${REP}_b${BATCH}_${TS}"

RAW_LOAD="${ROOT}/data/raw/load"
RAW_WL="${ROOT}/data/raw/workload"
RAW_META="${ROOT}/data/raw/meta"
RAW_FAULT="${ROOT}/data/raw/fault"
mkdir -p "$RAW_LOAD" "$RAW_WL" "$RAW_META" "$RAW_FAULT"

LOAD_LOG="${RAW_LOAD}/${RUN_ID}.log"
WL_LOG="${RAW_WL}/${RUN_ID}.log"
META="${RAW_META}/${RUN_ID}.json"
FAULT_JSON="${RAW_FAULT}/${RUN_ID}.json"

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

# ---------- DISPARA FAULT INJECT EM BACKGROUND (se aplicavel) ----------
FAULT_PID=""
if [[ "$PHASE" == "fault" && "$FAULT_TYPE" != "none" ]]; then
  if [[ ! -x "$FAULT_INJECT" ]]; then
    echo ">>> [ERRO] fault_inject.sh nao encontrado/executavel em: $FAULT_INJECT" >&2
    exit 4
  fi
  echo ">>> [fault] dispatch background: $FAULT_TYPE  start=+${FAULT_START_OFFSET_S}s  dur=${FAULT_DURATION_S}s"
  "$FAULT_INJECT" \
      -f "$FAULT_TYPE" \
      -s "$FAULT_START_OFFSET_S" \
      -d "$FAULT_DURATION_S" \
      -o "$FAULT_JSON" \
      >> "${RAW_FAULT}/${RUN_ID}.fault.log" 2>&1 &
  FAULT_PID=$!
  echo ">>> [fault] pid=$FAULT_PID  json=$FAULT_JSON"
fi

# garante que ao morrer abruptamente o fault_inject e morto junto
cleanup_fault() {
  if [[ -n "$FAULT_PID" ]] && kill -0 "$FAULT_PID" 2>/dev/null; then
    echo ">>> [cleanup] interrompendo fault_inject pid=$FAULT_PID" >&2
    kill -TERM "$FAULT_PID" 2>/dev/null || true
    wait "$FAULT_PID" 2>/dev/null || true
  fi
}
trap cleanup_fault EXIT INT TERM

# ---------- RUN (workload) ----------
echo ">>> [run] -> $WL_LOG"
"$YCSB" run cassandra-cql -P "$WORKLOAD_FILE" \
  "${CQL_PROPS[@]}" \
  -p cassandra.readconsistencylevel="$CONSISTENCY" \
  -p cassandra.writeconsistencylevel="$CONSISTENCY" \
  -threads "$THREADS" \
  -s 2>&1 | tee "$WL_LOG"
RUN_RC=${PIPESTATUS[0]}

# espera o fault_inject terminar (recuperacao incluida)
if [[ -n "$FAULT_PID" ]]; then
  echo ">>> [fault] aguardando fault_inject terminar..."
  wait "$FAULT_PID" || echo ">>> [fault] fault_inject exit != 0 (verificar fault.log)"
  FAULT_PID=""
fi
trap - EXIT INT TERM

if [[ "$RUN_RC" -ne 0 ]]; then
  echo ">>> [ERRO] run falhou (rc=$RUN_RC). Abortando sem gravar meta." >&2
  exit "$RUN_RC"
fi

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
  "batch": "${BATCH}",
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
  "maxexecutiontime_s": $(jnull "$MAXEXECTIME"),
  "cluster_nodes": ${CLUSTER_NODES},
  "cassandra_version": "${CASSANDRA_VERSION}",
  "env": "${ENV}",
  "hosts": $(jstr "$HOSTS"),
  "notes": $(jstr "$NOTES")
}
EOF

echo ">>> meta -> $META"
echo ">>> OK: $RUN_ID"
