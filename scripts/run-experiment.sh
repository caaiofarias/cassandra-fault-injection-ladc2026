#!/bin/bash
set -e

# Configurações ajustáveis
YCSB_DIR="${YCSB_DIR:-$HOME/ycsb-0.17.0}"
HOSTS="${HOSTS:-localhost}"
CONSISTENCY="${CONSISTENCY:-ONE}"
THREADS="${THREADS:-10}"
RECORDS="${RECORDS:-1000}"
OPERATIONS="${OPERATIONS:-1000}"
OUTPUT_DIR_WORK="${OUTPUT_DIR:-../data/raw/workload}"
OUTPUT_DIR_LOAD="${OUTPUT_DIR:-../data/raw/load}"

# Criar diretório de output
mkdir -p "$OUTPUT_DIR_LOAD"
mkdir -p "$OUTPUT_DIR_WORK"

# Timestamp para o nome do arquivo
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_FILE="$OUTPUT_DIR_WORK/baseline_${CONSISTENCY}_${THREADS}t_${TIMESTAMP}.txt"
LOAD_FILE="$OUTPUT_DIR_LOAD/baseline_${CONSISTENCY}_${THREADS}t_${TIMESTAMP}.txt.load"


echo "==> [LOAD] Populando tabela com $RECORDS registros..."
"$YCSB_DIR/bin/ycsb.sh" load cassandra-cql \
  -P "$YCSB_DIR/workloads/workloada" \
  -p hosts="$HOSTS" \
  -p recordcount="$RECORDS" \
  -p cassandra.writeconsistencylevel="$CONSISTENCY" \
  -threads "$THREADS" \
  > "$LOAD_FILE" 2>&1


echo ""
echo "==> [RUN] Executando $OPERATIONS operações..."
"$YCSB_DIR/bin/ycsb.sh" run cassandra-cql \
  -P "$YCSB_DIR/workloads/workloada" \
  -p hosts="$HOSTS" \
  -p recordcount="$RECORDS" \
  -p operationcount="$OPERATIONS" \
  -p cassandra.readconsistencylevel="$CONSISTENCY" \
  -p cassandra.writeconsistencylevel="$CONSISTENCY" \
  -threads "$THREADS" \
  > "$RUN_FILE" 2>&1
