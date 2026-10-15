# seed 1
gcloud compute ssh cassandra-node-1 --zone=us-central1-a --command="sudo systemctl start cassandra"
echo ">>> node-1 iniciado, aguardando 45s..."
sleep 45

# seed 2
gcloud compute ssh cassandra-node-2 --zone=us-central1-a --command="sudo systemctl start cassandra"
echo ">>> node-2 iniciado, aguardando 45s..."
sleep 45

# demais
for i in $(seq 3 5); do
  echo ">>> subindo node-$i..."
  gcloud compute ssh cassandra-node-$i --zone=us-central1-a --command="sudo systemctl start cassandra"
  sleep 45
  echo ">>> node-$i aguardado"
done

echo ">>> verificando cluster..."
gcloud compute ssh cassandra-node-1 --zone=us-central1-a --command="nodetool status"