#!/bin/bash

if [ ! "$DB_PASSWORD" ]
then
	echo "Please set $DB_PASSWORD" 1>&2
	exit 1
fi

N="${1:-1}"

T="$(date +%s)"

echo "spawning $N rds instances"

for I in $(seq 1 "$N")
do

	echo "spawning instance $I"

	IID="hasura-cloud-benchmark-V2-$I"

	aws --profile=hasura --region=ap-south-1 rds create-db-instance            \
		--db-instance-identifier "$IID"                                          \
		--engine postgres                                                        \
		--tags Key=purpose,Value=hasura-cloud-benchmark                          \
		--db-instance-class db.m5.xlarge                                         \
		--allocated-storage 20                                                   \
		--master-username master                                                 \
		--master-user-password "$DB_PASSWORD"                                    \
		--publicly-accessible                                                    \
		| tee "logs/aws_rds_logs_${T}_${I}.json"

	aws --profile=hasura \
		--region=ap-south-1 rds describe-db-instances \
		--db-instance-identifier="$IID" \
		| jq -r '.DBInstances | .[] | .Endpoint.Address' \
		> "logs/aws_rds_logs_${T}_${I}_connection_string.txt"

done
