#!/usr/bin/env bash
###############################################################################
# fault_inject.sh (v2) — Injeção de falhas controlada no cluster Cassandra/GCP
#
# Tipos suportados:
#   node_crash     systemctl stop cassandra em cassandra-node-3 (réplica)
#   coord_crash    systemctl stop cassandra em cassandra-node-1 (contact point)
#   net_delay      tc/netem: delay no egress de cassandra-node-3 (timing fault)
#   net_loss       tc/netem: packet loss no egress de cassandra-node-3 (omission)
#   net_partition  iptables: isola cassandra-node-3 dos demais nós (partição)
#
# Timeline:  0s ── (start_offset) injeta ── (+duration) remove ── poll recovery
#
# Saída: JSON com 5 timestamps reais (epoch) p/ cálculo de MTTR/availability.
#
# Uso:
#   ./fault_inject.sh -f <tipo> [-s offset] [-d duracao] [-o saida.json]
#                     [--delay-ms N] [--jitter-ms N] [--loss-pct N]
#
# Execução: máquina LOCAL (precisa de gcloud autenticado).
# Mock: export GCLOUD_BIN=./mock_gcloud para testar sem tocar nas VMs.
###############################################################################
set -euo pipefail

# ----------------------------- Configuração ---------------------------------
ZONE="us-central1-a"
GCLOUD="${GCLOUD_BIN:-gcloud}"
IFACE="ens4"                       # interface padrão das VMs e2 no GCP

# Topologia do cluster (nome -> IP interno)
declare -A NODE_IP=(
  [cassandra-node-1]=10.128.0.2
  [cassandra-node-2]=10.128.0.3
  [cassandra-node-3]=10.128.0.4
  [cassandra-node-4]=10.128.0.5
  [cassandra-node-5]=10.128.0.6
)
ALL_NODES=(cassandra-node-1 cassandra-node-2 cassandra-node-3 cassandra-node-4 cassandra-node-5)
CLUSTER_SIZE=5

# Defaults da CLI
FAULT_TYPE=""
START_OFFSET=60
DURATION=60
OUTPUT="fault_result.json"
RECOVERY_TIMEOUT=120
POLL_INTERVAL=5
DELAY_MS=200
JITTER_MS=50
LOSS_PCT=25

# ----------------------------- CLI ------------------------------------------
usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f) FAULT_TYPE="$2"; shift 2 ;;
    -s) START_OFFSET="$2"; shift 2 ;;
    -d) DURATION="$2"; shift 2 ;;
    -o) OUTPUT="$2"; shift 2 ;;
    --delay-ms)  DELAY_MS="$2";  shift 2 ;;
    --jitter-ms) JITTER_MS="$2"; shift 2 ;;
    --loss-pct)  LOSS_PCT="$2";  shift 2 ;;
    -h|--help) usage ;;
    *) echo "ERRO: argumento desconhecido: $1" >&2; usage ;;
  esac
done

case "$FAULT_TYPE" in
  node_crash)    TARGET="cassandra-node-3" ;;
  coord_crash)   TARGET="cassandra-node-1" ;;
  net_delay)     TARGET="cassandra-node-3" ;;
  net_loss)      TARGET="cassandra-node-3" ;;
  net_partition) TARGET="cassandra-node-3" ;;
  *) echo "ERRO: -f deve ser node_crash|coord_crash|net_delay|net_loss|net_partition" >&2; exit 1 ;;
esac

# Nó saudável usado para poll do nodetool (nunca o alvo da falha)
if [[ "$TARGET" == "cassandra-node-1" ]]; then
  POLL_NODE="cassandra-node-2"
else
  POLL_NODE="cassandra-node-1"
fi

log() { echo "[$(date -u +%H:%M:%S)] $*" >&2; }

ssh_cmd() {  # ssh_cmd <node> <comando remoto>
  "$GCLOUD" compute ssh "$1" --zone="$ZONE" --quiet --command="$2"
}

# ----------------------------- Inject / Remove ------------------------------
PEER_IPS=()
for n in "${ALL_NODES[@]}"; do
  [[ "$n" == "$TARGET" ]] && continue
  PEER_IPS+=("${NODE_IP[$n]}")
done

# precleanup: remove QUALQUER estado residual no alvo antes de injetar.
# Garante que um run anterior abortado (Ctrl-C, SSH caiu, etc.) nao
# contamine este run. Idempotente e silencioso.
precleanup() {
  case "$FAULT_TYPE" in
    net_delay|net_loss)
      ssh_cmd "$TARGET" "sudo tc qdisc del dev $IFACE root 2>/dev/null || true" || true
      ;;
    net_partition)
      ssh_cmd "$TARGET" "sudo iptables -D INPUT  -j CASS_FAULT 2>/dev/null || true
sudo iptables -D OUTPUT -j CASS_FAULT 2>/dev/null || true
sudo iptables -F CASS_FAULT 2>/dev/null || true
sudo iptables -X CASS_FAULT 2>/dev/null || true" || true
      ;;
  esac
}

# verifica que a remocao realmente limpou o estado; retorna 0 se limpo.
verify_clean() {
  case "$FAULT_TYPE" in
    net_delay|net_loss)
      local q; q="$(ssh_cmd "$TARGET" "tc qdisc show dev $IFACE | grep -c netem || true" | tr -dc '0-9')"
      [[ "${q:-0}" == "0" ]]
      ;;
    net_partition)
      local c; c="$(ssh_cmd "$TARGET" "sudo iptables -L CASS_FAULT -n 2>/dev/null | grep -c DROP || true" | tr -dc '0-9')"
      [[ "${c:-0}" == "0" ]]
      ;;
    *) return 0 ;;
  esac
}

inject_fault() {
  case "$FAULT_TYPE" in
    node_crash|coord_crash)
      ssh_cmd "$TARGET" "sudo systemctl stop cassandra"
      ;;
    net_delay)
      ssh_cmd "$TARGET" \
        "sudo tc qdisc add dev $IFACE root netem delay ${DELAY_MS}ms ${JITTER_MS}ms"
      ;;
    net_loss)
      ssh_cmd "$TARGET" \
        "sudo tc qdisc add dev $IFACE root netem loss ${LOSS_PCT}%"
      ;;
    net_partition)
      # Chain dedicada: remoção atômica e sem risco de apagar regra alheia.
      # DROP apenas de/para os IPs internos dos pares -> SSH (IP externo) intacto.
      local rules="sudo iptables -N CASS_FAULT 2>/dev/null || true
sudo iptables -I INPUT  -j CASS_FAULT
sudo iptables -I OUTPUT -j CASS_FAULT"
      for ip in "${PEER_IPS[@]}"; do
        rules+="
sudo iptables -A CASS_FAULT -s $ip -j DROP
sudo iptables -A CASS_FAULT -d $ip -j DROP"
      done
      ssh_cmd "$TARGET" "$rules"
      ;;
  esac
}

remove_fault() {
  case "$FAULT_TYPE" in
    node_crash|coord_crash)
      ssh_cmd "$TARGET" "sudo systemctl start cassandra"
      ;;
    net_delay|net_loss)
      ssh_cmd "$TARGET" "sudo tc qdisc del dev $IFACE root 2>/dev/null || true"
      ;;
    net_partition)
      ssh_cmd "$TARGET" "sudo iptables -D INPUT  -j CASS_FAULT 2>/dev/null || true
sudo iptables -D OUTPUT -j CASS_FAULT 2>/dev/null || true
sudo iptables -F CASS_FAULT 2>/dev/null || true
sudo iptables -X CASS_FAULT 2>/dev/null || true"
      ;;
  esac
}

# ----------------------------- Recovery check -------------------------------
count_un() {  # conta linhas "UN" no nodetool status visto a partir de <node>
  ssh_cmd "$1" "nodetool status 2>/dev/null | grep -c '^UN' || true" | tail -n1
}

confirm_recovery() {
  local deadline=$(( $(date +%s) + RECOVERY_TIMEOUT ))
  case "$FAULT_TYPE" in
    node_crash|coord_crash|net_loss|net_delay)
      # Visão de um nó saudável: cluster 5/5 UN
      while (( $(date +%s) < deadline )); do
        local un; un="$(count_un "$POLL_NODE" | tr -dc '0-9')"
        log "recovery poll ($POLL_NODE): ${un:-?}/$CLUSTER_SIZE UN"
        [[ "${un:-0}" == "$CLUSTER_SIZE" ]] && return 0
        sleep "$POLL_INTERVAL"
      done
      ;;
    net_partition)
      # Reconvergência do gossip exige acordo DOS DOIS lados da partição
      while (( $(date +%s) < deadline )); do
        local a b
        a="$(count_un "$POLL_NODE" | tr -dc '0-9')"
        b="$(count_un "$TARGET"    | tr -dc '0-9')"
        log "recovery poll: $POLL_NODE=${a:-?}/$CLUSTER_SIZE, $TARGET=${b:-?}/$CLUSTER_SIZE UN"
        [[ "${a:-0}" == "$CLUSTER_SIZE" && "${b:-0}" == "$CLUSTER_SIZE" ]] && return 0
        sleep "$POLL_INTERVAL"
      done
      ;;
  esac
  return 1
}

# ----------------------------- Cleanup garantido ----------------------------
FAULT_ACTIVE=0
CLEAN_OK=true
cleanup() {
  # ignora sinais durante a propria limpeza: um 2o Ctrl-C nao interrompe mais.
  trap '' INT TERM
  if [[ "$FAULT_ACTIVE" == "1" ]]; then
    log "ATENÇÃO: saída abrupta com falha ativa — executando remoção de emergência"
    remove_fault || log "ERRO: remoção de emergência falhou — tentando novamente"
    # segunda tentativa + verificacao para falhas de rede
    if [[ "$FAULT_TYPE" == net_* ]]; then
      verify_clean || { remove_fault || true; }
      verify_clean || log "ERRO GRAVE: estado PERSISTE em $TARGET — VERIFICAR MANUALMENTE"
    fi
  fi
}
trap cleanup EXIT INT TERM

# ----------------------------- Timeline -------------------------------------
T_SCRIPT_START=$(date +%s)
log "fault=$FAULT_TYPE target=$TARGET offset=${START_OFFSET}s duration=${DURATION}s"

log "pre-cleanup: removendo qualquer estado residual no alvo"
precleanup

log "estabilização: aguardando ${START_OFFSET}s"
sleep "$START_OFFSET"

log "injetando falha"
INJECT_RC=0; inject_fault || INJECT_RC=$?
T_INJECTED=$(date +%s)
FAULT_ACTIVE=1

log "falha ativa por ${DURATION}s"
sleep "$DURATION"

log "removendo falha"
REMOVE_RC=0; remove_fault || REMOVE_RC=$?
T_REMOVED=$(date +%s)
FAULT_ACTIVE=0

# verifica que a remocao limpou o estado de rede; se nao, tenta de novo.
# (crash nao tem estado a verificar; recovery confirma via nodetool adiante)
if [[ "$FAULT_TYPE" == net_delay || "$FAULT_TYPE" == net_loss || "$FAULT_TYPE" == net_partition ]]; then
  if ! verify_clean; then
    log "AVISO: estado residual detectado apos remove_fault — repetindo limpeza"
    remove_fault || true
    if verify_clean; then
      log "limpeza confirmada na segunda tentativa"
    else
      log "ERRO GRAVE: estado de falha PERSISTE em $TARGET — VERIFICAR MANUALMENTE"
      CLEAN_OK=false
    fi
  fi
fi

log "confirmando recovery (timeout ${RECOVERY_TIMEOUT}s)"
if confirm_recovery; then
  T_RECOVERED=$(date +%s)
  RECOVERY_OK=true
  log "recovery confirmado em $(( T_RECOVERED - T_REMOVED ))s"
else
  T_RECOVERED=null
  RECOVERY_OK=false
  log "ERRO: recovery NÃO confirmado dentro do timeout"
fi

# ----------------------------- JSON de saída --------------------------------
cat > "$OUTPUT" <<EOF
{
  "fault_type": "$FAULT_TYPE",
  "target_node": "$TARGET",
  "zone": "$ZONE",
  "start_offset_s_planned": $START_OFFSET,
  "duration_s_planned": $DURATION,
  "fault_params": {
    "delay_ms": $DELAY_MS,
    "jitter_ms": $JITTER_MS,
    "loss_pct": $LOSS_PCT
  },
  "t_script_start_epoch": $T_SCRIPT_START,
  "t_fault_injected_epoch": $T_INJECTED,
  "t_fault_removed_epoch": $T_REMOVED,
  "t_recovery_confirmed_epoch": $T_RECOVERED,
  "recovery_confirmed": $RECOVERY_OK,
  "clean_confirmed": $CLEAN_OK,
  "inject_rc": $INJECT_RC,
  "remove_rc": $REMOVE_RC
}
EOF

log "resultado gravado em $OUTPUT"
[[ "$RECOVERY_OK" == "true" && "$CLEAN_OK" == "true" ]] || exit 2