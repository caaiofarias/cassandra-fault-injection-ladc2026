#!/bin/bash
# bootstrap-cluster.sh — sobe nós Cassandra sequencialmente com delay seguro
# Evita token collision causada por inicialização paralela
#
# Uso: ./bootstrap-cluster.sh
# Variáveis:
#   NODES         — lista de nós (default: "cassandra1 cassandra2 cassandra3 cassandra4 cassandra5")
#   DELAY_PER_NODE — segundos de espera entre nós (default: 90)

set -e

NODES="${NODES:-cassandra1 cassandra2 cassandra3 cassandra4 cassandra5}"
DELAY_PER_NODE="${DELAY_PER_NODE:-90}"

NODE_COUNT=$(echo "$NODES" | wc -w)

echo "════════════════════════════════════════════════════════"
echo "  Bootstrap sequencial do cluster Cassandra"
echo "════════════════════════════════════════════════════════"
echo "  Nós:   $NODES"
echo "  Total: $NODE_COUNT nós"
echo "  Delay: ${DELAY_PER_NODE}s entre cada nó"
echo "  Tempo estimado: $(( NODE_COUNT * DELAY_PER_NODE / 60 )) min"
echo "════════════════════════════════════════════════════════"
echo ""

i=1
for node in $NODES; do
  echo ""
  echo "==> [${i}/${NODE_COUNT}] Subindo ${node}..."
  docker compose up -d "$node"
  
  if [ "$i" -lt "$NODE_COUNT" ]; then
    echo "    Aguardando ${DELAY_PER_NODE}s antes do próximo nó..."
    echo "    (isso evita token collision por inicialização paralela)"
    
    # Conta regressiva visual
    for s in $(seq $DELAY_PER_NODE -10 10); do
      echo "    ${s}s restantes..."
      sleep 10
    done
  fi
  
  i=$((i + 1))
done

echo ""
echo "==> Todos os nós iniciados. Aguardando 30s para estabilização final..."
sleep 30

echo ""
echo "════════════════════════════════════════════════════════"
echo "  Status final do cluster"
echo "════════════════════════════════════════════════════════"
docker exec cassandra1 nodetool status

# Conta nós UN
UN_COUNT=$(docker exec cassandra1 nodetool status 2>/dev/null | grep -E '^UN' | wc -l | tr -d ' \n')

echo ""
if [ "$UN_COUNT" = "$NODE_COUNT" ]; then
  echo "✅ SUCESSO: Todos os ${NODE_COUNT} nós estão UN!"
  echo ""
  echo "Próximo passo: ./setup-schema.sh"
else
  echo "⚠️  ATENÇÃO: Apenas ${UN_COUNT}/${NODE_COUNT} nós estão UN"
  echo "   Aguarde mais 1-2 minutos e verifique com:"
  echo "   docker exec cassandra1 nodetool status"
fi
echo "════════════════════════════════════════════════════════"
