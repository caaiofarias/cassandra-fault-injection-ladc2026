for i in $(seq 1 5); do
  gcloud compute instances start cassandra-node-$i --zone=us-central1-a
done