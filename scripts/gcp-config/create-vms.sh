for i in $(seq 1 6); do
  gcloud compute instances create cassandra-node-$i \
    --project=$PROJECT \
    --zone=$ZONE \
    --machine-type=$MACHINE \
    --image=$IMAGE \
    --image-project=$IMAGE_PROJECT \
    --boot-disk-size=20GB \
    --boot-disk-type=pd-standard \
    --tags=cassandra \
    && echo ">>> node-$i criado"
done