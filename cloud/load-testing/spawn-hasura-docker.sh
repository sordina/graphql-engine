#!/bin/bash

if [ ! "$DB_URL" ]
then
	echo "Please set DB_URL environment variable" 1>&2
	exit 1
fi

for port in $(seq 8888 8900)
do
  docker run -d -p "$port:8080" \
    -e HASURA_GRAPHQL_DATABASE_URL="$DB_URL" \
    -e HASURA_GRAPHQL_ENABLE_CONSOLE=true \
    hasura/graphql-engine:v1.1.0
done
