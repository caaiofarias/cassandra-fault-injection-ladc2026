#!/bin/bash
# setup-schema.sh — cria keyspace e tabela para YCSB em cluster de 5 nós
# Uso: ./setup-schema.sh
# Variáveis ajustáveis:
#   REPLICATION_FACTOR (default: 3) — fator de replicação do keyspace

set -e

REPLICATION_FACTOR="${REPLICATION_FACTOR:-3}"

echo "==> Verificando se todos os 5 nós estão UP/Normal..."
echo "    Aguardando cluster formar (pode demorar 2-3 minutos)..."

# Espera até que nodetool status mostre 5 nós UN
MAX_WAIT=300  # 5 minutos
ELAPSED=0
INTERVAL=3

while [ $ELAPSED -lt $MAX_WAIT ]; do
  UN_COUNT=$(docker exec cassandra1 nodetool status 2>/dev/null | grep -cE '^UN' || echo "0")
  if [ "$UN_COUNT" -eq 5 ]; then
    echo "    ✅ Todos os 5 nós estão UN!"
    break
  fi
  echo "    Nós UN até agora: $UN_COUNT/5 (aguardando ${INTERVAL}s, ${ELAPSED}s decorridos)"
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [ "$UN_COUNT" -ne 5 ]; then
  echo "❌ ERRO: Cluster não formou completamente em ${MAX_WAIT}s"
  echo "    Estado atual:"
  docker exec cassandra1 nodetool status
  exit 1
fi

echo ""
echo "==> Estado atual do cluster:"
docker exec cassandra1 nodetool status

echo ""
echo "==> Criando keyspace 'ycsb' com replication_factor=${REPLICATION_FACTOR}..."
docker exec cassandra1 cqlsh -e "DROP KEYSPACE IF EXISTS ycsb;CREATE KEYSPACE ycsb WITH REPLICATION = {'class': 'SimpleStrategy', 'replication_factor': ${REPLICATION_FACTOR}};"

echo "==> Criando tabela 'usertable'..."
docker exec cassandra1 cqlsh -e "
USE ycsb; CREATE TABLE IF NOT EXISTS usertable (y_id varchar PRIMARY KEY,field0 varchar, field1 varchar, field2 varchar, field3 varchar, field4 varchar,field5 varchar, field6 varchar, field7 varchar, field8 varchar, field9 varchar);"

echo "==> Verificando schema criado:"
docker exec cassandra1 cqlsh -e "DESCRIBE TABLE ycsb.usertable;"

echo ""
echo "==> Verificando distribuição de tokens nos nós:"
docker exec cassandra1 nodetool describering ycsb 2>/dev/null | head -10 || echo "    (describering opcional, ignorando)"

echo ""
echo "✅ Schema criado com sucesso!"
echo ""
echo "   Replication Factor: ${REPLICATION_FACTOR}"
echo "   Níveis de consistência válidos com RF=${REPLICATION_FACTOR}:"
echo "     - ONE     (1 nó confirma)"
echo "     - QUORUM  ($(( (REPLICATION_FACTOR / 2) + 1 )) nós confirmam)"
echo "     - ALL     (${REPLICATION_FACTOR} nós confirmam)"
echo ""
echo "Próximo passo: rodar o YCSB com ./run-experiment.sh"