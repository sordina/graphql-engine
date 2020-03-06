#!/bin/bash

curl 'http://localhost:8888/v1/graphql' \
	-XPOST -H 'Content-Type: application/json' \
	--data-binary '{"query": "query { playlist_track { playlist_id track { name id album { id title artist { id name } } } } } " }'
