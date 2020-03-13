#!/bin/bash

if [ ! "$DB_PASSWORD" ]
then
	echo "Please set DB_PASSWORD environment variable" 1>&2
	exit 1
fi

if [ ! "$INSTANCES" ]
then
	INSTANCES=1
	echo "Defaulting instances to $INSTANCES" 1>&2
fi

if [ ! "$SECURITY_GROUPS" ]
then
	SECURITY_GROUPS="sg-0bf404f0e2975bcdc"
	echo "Defaulting SECURITY_GROUPS to $SECURITY_GROUPS" 1>&2
fi

T="$(date +%s)"

echo "spawning $INSTANCES rds instances"

# Request instances
#
for I in $(seq 1 "$INSTANCES")
do
	echo "spawning instance $I"
	IID="hasura-cloud-benchmark-V2-$I"

	aws --profile=hasura --region=ap-south-1 rds create-db-instance   \
		--db-instance-identifier "$IID"                                 \
		--engine postgres                                               \
		--tags Key=purpose,Value=hasura-cloud-benchmark                 \
		--db-instance-class db.m5.xlarge                                \
		--allocated-storage 20                                          \
		--master-username master                                        \
		--master-user-password "$DB_PASSWORD"                           \
		--publicly-accessible                                           \
		--vpc-security-group-ids "$SECURITY_GROUPS"                     \
		| tee "logs/aws_rds_logs_${T}_${I}.json"
done

# Check that instances started
#
for I in $(seq 1 "$INSTANCES")
do
	IID="hasura-cloud-benchmark-V2-$I"

	while \
		aws --profile=hasura \
			--region=ap-south-1 rds describe-db-instances \
			--db-instance-identifier="$IID" \
			| jq -r '.DBInstances | .[] | .Endpoint.Address' \
			| tee "logs/aws_rds_logs_${T}_${I}_connection_string.txt" \
			| grep -v rds 1>&2
	do
		echo "waiting for instance $I" 1>&2
	done

	echo "Instance $I up" 1>&2
	cat "logs/aws_rds_logs_${T}_${I}_connection_string.txt"
done
