# verifica cluster
gcloud compute ssh cassandra-node-1 --zone=us-central1-a \
  --command="nodetool status"

# cria keyspace
gcloud compute ssh cassandra-node-1 --zone=us-central1-a \
  --command="cqlsh localhost -e \"
    DROP KEYSPACE IF EXISTS ycsb;
    CREATE KEYSPACE ycsb WITH REPLICATION = {
      'class': 'SimpleStrategy', 'replication_factor': 3
    };\""

# cria tabela
gcloud compute ssh cassandra-node-1 --zone=us-central1-a \
  --command="cqlsh localhost -e \"
    USE ycsb;
    CREATE TABLE IF NOT EXISTS usertable (
      y_id varchar PRIMARY KEY,
      field0 varchar, field1 varchar, field2 varchar,
      field3 varchar, field4 varchar, field5 varchar,
      field6 varchar, field7 varchar, field8 varchar,
      field9 varchar
    );\""