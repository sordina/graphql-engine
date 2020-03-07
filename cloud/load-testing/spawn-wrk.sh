#!/bin/bash

wrk -s post.lua --timeout 12 -d 12 -t 1 -c 1 http://localhost:8888/v1/graphql
