#!/usr/bin/env bash
# shellcheck disable=SC2153  # NODES, NODE_IPS, HOSTS... vêm do cluster.env (sourced)
###############################################################################
# fault_inject.sh (v3) — injeção de falhas controlada no cluster Cassandra/GCP
#
# Tipos suportados (alvo padrão entre parênteses; -n sobrescreve):
#   node_crash     systemctl stop cassandra na réplica          (cassandra-node-3)
#   coord_crash    systemctl stop cassandra no contact point    (cassandra-node-1)
#   node_kill      SIGKILL no processo do Cassandra na réplica  (cassandra-node-3)
#                  crash ABRUPTO: o nó não avisa os pares (o systemctl stop dos dois
#                  tipos acima é desligamento ordenado e anuncia a saída pelo gossip)
#   node_silent    queda de MÁQUINA emulada no alvo              (cassandra-node-3)
#                  DROP silencioso de todo o tráfego Cassandra (7000/7001/9042, de e
#                  para qualquer IP — pares e clientes) + SIGKILL do processo. Com o
#                  SO vivo, o node_kill recusa conexões na hora (RST) e o coordenador
#                  desiste rápido; uma máquina que caiu não responde nada. O ssh (22)
#                  fica liberado para o controle; o boot da VM não entra na medida.
#   net_delay      tc/netem: delay no egress do alvo            (cassandra-node-3)
#   net_loss       tc/netem: perda de pacotes no egress do alvo (cassandra-node-3)
#   net_partition  iptables: isola o alvo dos demais nós        (cassandra-node-3)
#
# Timeline:
#   0 ── (start_offset) comando emitido ── efeito confirmado
#     ── (issued + duration) remoção emitida ── remoção confirmada ── 5/5 UN
#
# Carimbos (epoch com ms, relógio do cliente — o mesmo do YCSB):
#   t_inject_issued      antes de enviar o comando
#   t_inject_effective   efeito observado de FORA do alvo (critério em effect_definition)
#   t_remove_issued      antes de enviar a remoção
#   t_remove_effective   remoção observada
#   t_recovered          plano de controle: nodetool status 5/5 UN (dos dois lados, na partição)
#
# Em junho havia só dois carimbos, tomados DEPOIS do gcloud ssh retornar (~5 s
# de ssh + drenagem do systemctl stop): a falta já estava ativa havia até 19 s.
# Aqui o systemctl roda com --no-block e o efeito é medido à parte.
#
# Uso:
#   ./fault_inject.sh -f <tipo> [-n alvo] [-s offset] [-d duracao] [-o saida.json]
#                     [--delay-ms N] [--jitter-ms N] [--loss-pct N]
#   ./fault_inject.sh -f <tipo> [-n alvo] --print-target   # só resolve o alvo e sai
#
# Roda na VM cliente. Lê nós/IPs de ../../cluster.env (gerado por
# infra/45-sync-scripts.sh; sobrescreva com CLUSTER_ENV=...). O ssh usa os
# aliases e a conexão reaproveitada do /etc/ssh/ssh_config.d/campaign.conf.
# Teste sem VMs: SSH_BIN=<ssh falso> TCP_PROBE=<probe falso>.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_ENV="${CLUSTER_ENV:-$SCRIPT_DIR/../../cluster.env}"
[[ -f "$CLUSTER_ENV" ]] || { echo "ERRO: $CLUSTER_ENV não existe (rode infra/45-sync-scripts.sh)" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CLUSTER_ENV"

SSH="${SSH_BIN:-ssh}"
CLUSTER_SIZE=${#NODES[@]}
declare -A NODE_IP
for i in "${!NODES[@]}"; do NODE_IP[${NODES[$i]}]="${NODE_IPS[$i]}"; done

# ----------------------------- Defaults da CLI ------------------------------
FAULT_TYPE=""
TARGET=""
START_OFFSET=60
DURATION=60
OUTPUT="fault_result.json"
RECOVERY_TIMEOUT=180
POLL_INTERVAL=1
EFFECT_TIMEOUT=60
REMOVE_TIMEOUT=""        # vazio = EFFECT_TIMEOUT; ver abaixo (node_kill/node_silent)
DELAY_MS=200
JITTER_MS=50
LOSS_PCT=25
PRINT_TARGET=0

usage() { awk '/^####/{n++; next} n==1' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f) FAULT_TYPE="$2"; shift 2 ;;
    -n|--target) TARGET="$2"; shift 2 ;;
    -s) START_OFFSET="$2"; shift 2 ;;
    -d) DURATION="$2"; shift 2 ;;
    -o) OUTPUT="$2"; shift 2 ;;
    --delay-ms)  DELAY_MS="$2";  shift 2 ;;
    --jitter-ms) JITTER_MS="$2"; shift 2 ;;
    --loss-pct)  LOSS_PCT="$2";  shift 2 ;;
    --print-target) PRINT_TARGET=1; shift ;;
    -h|--help) usage ;;
    *) echo "ERRO: argumento desconhecido: $1" >&2; usage ;;
  esac
done

case "$FAULT_TYPE" in
  node_crash)    DEFAULT_TARGET="cassandra-node-3" ;;
  coord_crash)   DEFAULT_TARGET="cassandra-node-1" ;;
  node_kill)     DEFAULT_TARGET="cassandra-node-3" ;;
  node_silent)   DEFAULT_TARGET="cassandra-node-3" ;;
  net_delay)     DEFAULT_TARGET="cassandra-node-3" ;;
  net_loss)      DEFAULT_TARGET="cassandra-node-3" ;;
  net_partition) DEFAULT_TARGET="cassandra-node-3" ;;
  *) echo "ERRO: -f deve ser node_crash|coord_crash|node_kill|node_silent|net_delay|net_loss|net_partition" >&2; exit 1 ;;
esac
TARGET="${TARGET:-$DEFAULT_TARGET}"
# Depois de um SIGKILL o Cassandra reprocessa o commitlog ao subir: a porta 9042 levou
# até 53 s no B6 e passou de 60 s numa execução do B7 (invalidada só por isso). Para
# esses tipos a CONFIRMAÇÃO da remoção espera até 180 s; o que se mede não muda.
case "$FAULT_TYPE" in
  node_kill|node_silent) : "${REMOVE_TIMEOUT:=180}" ;;
  *)                     : "${REMOVE_TIMEOUT:=$EFFECT_TIMEOUT}" ;;
esac
[[ -n "${NODE_IP[$TARGET]:-}" ]] || { echo "ERRO: alvo '$TARGET' não está em NODES (${NODES[*]})" >&2; exit 1; }
TARGET_IP="${NODE_IP[$TARGET]}"
if (( PRINT_TARGET )); then echo "$TARGET"; exit 0; fi

# Nó saudável usado para poll do nodetool e para testar a partição (nunca o alvo)
POLL_NODE=""
for n in "${NODES[@]}"; do [[ "$n" != "$TARGET" ]] && { POLL_NODE="$n"; break; }; done

PEER_IPS=()
for n in "${NODES[@]}"; do [[ "$n" != "$TARGET" ]] && PEER_IPS+=("${NODE_IP[$n]}"); done

now() { date +%s.%3N; }
log() { echo "[$(date -u +%H:%M:%S.%3N)] $*" >&2; }
ssh_cmd() { "$SSH" "$1" "$2"; }   # ssh_cmd <nó> <comando remoto>

# ----------------------------- Observação do efeito -------------------------
# tcp_open <ip> <porta> — a partir do cliente
tcp_open() {
  if [[ -n "${TCP_PROBE:-}" ]]; then "$TCP_PROBE" "$1" "$2"; return; fi
  timeout 1 bash -c "</dev/tcp/$1/$2" 2>/dev/null
}
# o par consegue abrir a porta de gossip do alvo? (a partição não isola o cliente)
peer_reaches_target() {
  ssh_cmd "$POLL_NODE" "timeout 1 bash -c '</dev/tcp/$TARGET_IP/7000'" >/dev/null 2>&1
}
netem_count() { ssh_cmd "$TARGET" "tc qdisc show dev $IFACE | grep -c netem || true" | tr -dc '0-9'; }
process_alive() { ssh_cmd "$TARGET" "pgrep -f 'org[.]apache[.]cassandra[.]service[.]CassandraDaemon' >/dev/null"; }
drop_count()  { ssh_cmd "$TARGET" "sudo iptables -L CASS_FAULT -n 2>/dev/null | grep -c DROP || true" | tr -dc '0-9'; }

case "$FAULT_TYPE" in
  node_crash|coord_crash|node_kill)
    EFFECT_DEF="injeção: 9042 e 7000 do alvo recusam conexão (visto do cliente); remoção: 9042 aceita" ;;
  net_delay|net_loss)
    EFFECT_DEF="injeção: qdisc netem presente em $IFACE do alvo; remoção: ausente" ;;
  net_partition)
    EFFECT_DEF="injeção: $POLL_NODE não abre 7000 do alvo; remoção: abre" ;;
  node_silent)
    EFFECT_DEF="injeção: regras DROP ativas no alvo e processo ausente; remoção: 9042 aceita" ;;
esac

effect_injected() {
  case "$FAULT_TYPE" in
    node_crash|coord_crash|node_kill) ! tcp_open "$TARGET_IP" 9042 && ! tcp_open "$TARGET_IP" 7000 ;;
    net_delay|net_loss)     (( $(netem_count || echo 0) > 0 )) ;;
    net_partition)          ! peer_reaches_target ;;
    node_silent)            (( $(drop_count || echo 0) > 0 )) && ! process_alive ;;
  esac
}
effect_removed() {
  case "$FAULT_TYPE" in
    node_crash|coord_crash|node_kill) tcp_open "$TARGET_IP" 9042 ;;
    net_delay|net_loss)     (( $(netem_count || echo 1) == 0 )) ;;
    net_partition)          peer_reaches_target ;;
    node_silent)            tcp_open "$TARGET_IP" 9042 ;;
  esac
}

# wait_for <função> <timeout_s> — ecoa o carimbo do instante em que a condição valeu
wait_for() {
  local fn="$1" deadline; deadline=$(( $(date +%s) + $2 ))
  while (( $(date +%s) < deadline )); do
    if "$fn"; then now; return 0; fi
    sleep 0.2
  done
  return 1
}

# ----------------------------- Inject / Remove ------------------------------
CLEAN_NET="sudo tc qdisc del dev $IFACE root 2>/dev/null || true
sudo iptables -D INPUT  -j CASS_FAULT 2>/dev/null || true
sudo iptables -D OUTPUT -j CASS_FAULT 2>/dev/null || true
sudo iptables -F CASS_FAULT 2>/dev/null || true
sudo iptables -X CASS_FAULT 2>/dev/null || true"

# Depois de um SIGKILL a unidade do systemd pode continuar "active" (unidade SysV com
# RemainAfterExit) e um start não faria nada: a remoção do node_kill reinicia a
# unidade, e só se o processo de fato não existir.
KILL_RESTART="pgrep -f 'org[.]apache[.]cassandra[.]service[.]CassandraDaemon' >/dev/null || sudo systemctl restart --no-block cassandra"

# precleanup: remove QUALQUER estado residual no alvo — de qualquer tipo de falta,
# não só do tipo atual — e religa o Cassandra se um run abortado o deixou parado.
precleanup() {
  ssh_cmd "$TARGET" "$CLEAN_NET
$KILL_RESTART" || true
}

# verifica que a remocao realmente limpou o estado; retorna 0 se limpo.
verify_clean() {
  case "$FAULT_TYPE" in
    net_delay|net_loss) [[ "$(netem_count)" == "0" ]] ;;
    net_partition|node_silent) [[ "$(drop_count)" == "0" ]] ;;
    *) return 0 ;;
  esac
}

inject_fault() {
  case "$FAULT_TYPE" in
    node_crash|coord_crash)
      ssh_cmd "$TARGET" "sudo systemctl stop --no-block cassandra" ;;
    node_kill)
      ssh_cmd "$TARGET" "sudo pkill -9 -f 'org[.]apache[.]cassandra[.]service[.]CassandraDaemon'" ;;
    node_silent)
      # as regras entram ANTES do kill: o RST/FIN que o kernel manda ao fechar os
      # sockets do processo morto também é descartado — os pares só veem silêncio
      ssh_cmd "$TARGET" "sudo iptables -N CASS_FAULT 2>/dev/null || true
sudo iptables -A CASS_FAULT -p tcp -m multiport --dports 7000,7001,9042 -j DROP
sudo iptables -A CASS_FAULT -p tcp -m multiport --sports 7000,7001,9042 -j DROP
sudo iptables -I INPUT  -j CASS_FAULT
sudo iptables -I OUTPUT -j CASS_FAULT
sudo pkill -9 -f 'org[.]apache[.]cassandra[.]service[.]CassandraDaemon'" ;;
    net_delay)
      ssh_cmd "$TARGET" "sudo tc qdisc add dev $IFACE root netem delay ${DELAY_MS}ms ${JITTER_MS}ms" ;;
    net_loss)
      ssh_cmd "$TARGET" "sudo tc qdisc add dev $IFACE root netem loss ${LOSS_PCT}%" ;;
    net_partition)
      # Chain dedicada: remoção atômica e sem risco de apagar regra alheia.
      # DROP apenas de/para os IPs internos dos pares -> cliente e SSH intactos.
      local rules="sudo iptables -N CASS_FAULT 2>/dev/null || true"
      for ip in "${PEER_IPS[@]}"; do
        rules+="
sudo iptables -A CASS_FAULT -s $ip -j DROP
sudo iptables -A CASS_FAULT -d $ip -j DROP"
      done
      # a chain só entra em INPUT/OUTPUT depois de completa: o corte é um instante só
      rules+="
sudo iptables -I INPUT  -j CASS_FAULT
sudo iptables -I OUTPUT -j CASS_FAULT"
      ssh_cmd "$TARGET" "$rules" ;;
  esac
}

remove_fault() {
  case "$FAULT_TYPE" in
    node_crash|coord_crash) ssh_cmd "$TARGET" "sudo systemctl start --no-block cassandra" ;;
    node_kill) ssh_cmd "$TARGET" "$KILL_RESTART" ;;
    node_silent) ssh_cmd "$TARGET" "$CLEAN_NET
$KILL_RESTART" ;;
    net_delay|net_loss|net_partition) ssh_cmd "$TARGET" "$CLEAN_NET" ;;
  esac
}

# ----------------------------- Recovery check -------------------------------
count_un() {  # nós "UN" no nodetool status visto a partir de <node>
  ssh_cmd "$1" "nodetool status 2>/dev/null | grep -c '^UN' || true" | tail -n1 | tr -dc '0-9'
}

confirm_recovery() {
  local deadline=$(( $(date +%s) + RECOVERY_TIMEOUT )) a b
  while (( $(date +%s) < deadline )); do
    a="$(count_un "$POLL_NODE")"
    if [[ "$FAULT_TYPE" == net_partition ]]; then
      # reconvergência do gossip exige acordo DOS DOIS lados da partição
      b="$(count_un "$TARGET")"
      log "recovery poll: $POLL_NODE=${a:-?}/$CLUSTER_SIZE, $TARGET=${b:-?}/$CLUSTER_SIZE UN"
      [[ "${a:-0}" == "$CLUSTER_SIZE" && "${b:-0}" == "$CLUSTER_SIZE" ]] && return 0
    else
      log "recovery poll ($POLL_NODE): ${a:-?}/$CLUSTER_SIZE UN"
      [[ "${a:-0}" == "$CLUSTER_SIZE" ]] && return 0
    fi
    sleep "$POLL_INTERVAL"
  done
  return 1
}

# ----------------------------- Cleanup garantido ----------------------------
FAULT_ACTIVE=0
CLEAN_OK=true
cleanup() {
  # ignora sinais durante a propria limpeza: um 2o Ctrl-C nao interrompe mais.
  trap '' INT TERM
  trap - EXIT
  if [[ "$FAULT_ACTIVE" == "1" ]]; then
    log "ATENÇÃO: saída abrupta com falha ativa — executando remoção de emergência"
    remove_fault || log "ERRO: remoção de emergência falhou — tentando novamente"
    if [[ "$FAULT_TYPE" == net_* || "$FAULT_TYPE" == node_silent ]]; then
      verify_clean || { remove_fault || true; }
      verify_clean || log "ERRO GRAVE: estado PERSISTE em $TARGET — VERIFICAR MANUALMENTE"
    fi
  fi
}
# INT/TERM saem (e o EXIT faz a limpeza). Na v2 o handler rodava e o script
# SEGUIA a linha do tempo: um Ctrl-C deixava a falta ativa até o fim da duração.
trap cleanup EXIT
trap 'log "sinal INT recebido"; exit 130' INT
trap 'log "sinal TERM recebido"; exit 143' TERM

# sleep em background + wait: o bash só atende um sinal quando o comando em
# primeiro plano termina, e wait é interrompível; sleep em primeiro plano não.
sleep_until() {  # sleep_until <epoch com fração>
  local r; r="$(awk -v t="$1" -v n="$(now)" 'BEGIN { r = t - n; print (r > 0 ? r : 0) }')"
  sleep "$r" & wait $!
}
jnum() { [[ -z "$1" ]] && printf 'null' || printf '%s' "$1"; }

# ----------------------------- Timeline -------------------------------------
T_SCRIPT_START="$(now)"
log "fault=$FAULT_TYPE target=$TARGET ($TARGET_IP) poll=$POLL_NODE offset=${START_OFFSET}s duration=${DURATION}s"

log "pre-cleanup: removendo qualquer estado residual no alvo"
precleanup

log "estabilização: aguardando até +${START_OFFSET}s"
sleep_until "$(awk -v t="$T_SCRIPT_START" -v o="$START_OFFSET" 'BEGIN { printf "%.3f", t + o }')"

log "injetando falha (comando emitido)"
T_INJECT_ISSUED="$(now)"
FAULT_ACTIVE=1
INJECT_RC=0; inject_fault || INJECT_RC=$?
if T_INJECT_EFFECTIVE="$(wait_for effect_injected "$EFFECT_TIMEOUT")"; then
  INJECT_OK=true
  log "efeito confirmado (+$(awk -v a="$T_INJECT_ISSUED" -v b="$T_INJECT_EFFECTIVE" 'BEGIN{printf "%.3f", b-a}')s)"
else
  T_INJECT_EFFECTIVE=""; INJECT_OK=false
  log "ERRO: efeito NÃO confirmado em ${EFFECT_TIMEOUT}s ($EFFECT_DEF)"
fi

log "falha ativa até issued+${DURATION}s"
sleep_until "$(awk -v t="$T_INJECT_ISSUED" -v d="$DURATION" 'BEGIN { printf "%.3f", t + d }')"

log "removendo falha (comando emitido)"
T_REMOVE_ISSUED="$(now)"
REMOVE_RC=0; remove_fault || REMOVE_RC=$?
FAULT_ACTIVE=0
if T_REMOVE_EFFECTIVE="$(wait_for effect_removed "$REMOVE_TIMEOUT")"; then
  REMOVE_OK=true
  log "remoção confirmada (+$(awk -v a="$T_REMOVE_ISSUED" -v b="$T_REMOVE_EFFECTIVE" 'BEGIN{printf "%.3f", b-a}')s)"
else
  T_REMOVE_EFFECTIVE=""; REMOVE_OK=false
  log "ERRO: remoção NÃO confirmada em ${REMOVE_TIMEOUT}s"
fi

# verifica que a remocao limpou o estado de rede; se nao, tenta de novo.
if [[ "$FAULT_TYPE" == net_* || "$FAULT_TYPE" == node_silent ]] && ! verify_clean; then
  log "AVISO: estado residual detectado apos remove_fault — repetindo limpeza"
  remove_fault || true
  if verify_clean; then
    log "limpeza confirmada na segunda tentativa"
  else
    log "ERRO GRAVE: estado de falha PERSISTE em $TARGET — VERIFICAR MANUALMENTE"
    CLEAN_OK=false
  fi
fi

log "confirmando recovery de plano de controle (timeout ${RECOVERY_TIMEOUT}s)"
if confirm_recovery; then
  T_RECOVERED="$(now)"; RECOVERY_OK=true
  log "recovery confirmado em $(awk -v a="$T_REMOVE_ISSUED" -v b="$T_RECOVERED" 'BEGIN{printf "%.3f", b-a}')s após a remoção"
else
  T_RECOVERED=""; RECOVERY_OK=false
  log "ERRO: recovery NÃO confirmado dentro do timeout"
fi

# ----------------------------- JSON de saída --------------------------------
cat > "$OUTPUT" <<EOF
{
  "schema_version": 3,
  "fault_type": "$FAULT_TYPE",
  "target_node": "$TARGET",
  "target_ip": "$TARGET_IP",
  "poll_node": "$POLL_NODE",
  "zone": "${ZONE:-}",
  "start_offset_s_planned": $START_OFFSET,
  "duration_s_planned": $DURATION,
  "fault_params": {
    "delay_ms": $DELAY_MS,
    "jitter_ms": $JITTER_MS,
    "loss_pct": $LOSS_PCT
  },
  "effect_definition": "$EFFECT_DEF",
  "t_script_start_epoch": $T_SCRIPT_START,
  "t_inject_issued_epoch": $T_INJECT_ISSUED,
  "t_inject_effective_epoch": $(jnum "$T_INJECT_EFFECTIVE"),
  "t_remove_issued_epoch": $T_REMOVE_ISSUED,
  "t_remove_effective_epoch": $(jnum "$T_REMOVE_EFFECTIVE"),
  "t_recovered_epoch": $(jnum "$T_RECOVERED"),
  "inject_confirmed": $INJECT_OK,
  "remove_confirmed": $REMOVE_OK,
  "recovery_confirmed": $RECOVERY_OK,
  "clean_confirmed": $CLEAN_OK,
  "inject_rc": $INJECT_RC,
  "remove_rc": $REMOVE_RC,
  "legacy_note": "t_fault_* abaixo = chaves da v2, para scripts antigos de análise: injected=inject_effective (ou issued), removed=remove_issued, recovery=recovered",
  "t_fault_injected_epoch": $(jnum "${T_INJECT_EFFECTIVE:-$T_INJECT_ISSUED}"),
  "t_fault_removed_epoch": $T_REMOVE_ISSUED,
  "t_recovery_confirmed_epoch": $(jnum "$T_RECOVERED")
}
EOF

log "resultado gravado em $OUTPUT"
[[ "$INJECT_OK" == true && "$REMOVE_OK" == true && "$RECOVERY_OK" == true && "$CLEAN_OK" == true ]] || exit 2
