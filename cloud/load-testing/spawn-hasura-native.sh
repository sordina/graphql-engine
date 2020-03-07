#!/bin/bash

if [ ! "$DB_URL" ]
then
        echo "Please set DB_URL environment variable" 1>&2
        exit 1
fi

for HASURA_GRAPHQL_SERVER_PORT in $(seq 8888 8888)
do
  echo "spawning hasura on port $HASURA_GRAPHQL_SERVER_PORT"
  export HASURA_GRAPHQL_SERVER_PORT
  HASURA_GRAPHQL_DATABASE_URL="$DB_URL" ~/graphql-engine serve &
  processid=$!
done

wait $processid
