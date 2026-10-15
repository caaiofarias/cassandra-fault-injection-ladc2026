for i in $(seq 1 5); do
  gcloud compute instances stop cassandra-node-$i --zone=us-central1-a
done