#!/bin/bash

if [ ! "$DB_URL" ]
then
	echo "Please set DB_URL environment variable" 1>&2
	exit 1
fi

docker run -p 8888:8080 \
  -e HASURA_GRAPHQL_DATABASE_URL="$DB_URL" \
  -e HASURA_GRAPHQL_ENABLE_CONSOLE=true \
  hasura/graphql-engine:latest
