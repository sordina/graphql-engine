#!/bin/bash

N="${1:-1}"

if [ ! "$N" ]
then
	echo "Defaulting instances to $N" 1>&2
fi

if [ ! "$AMI_NAME" ]
then
	echo "You need to specify the AMI_NAME variable" 1>&2
fi

if [ ! "$SECURITY_GROUP" ]
then
	echo "You need to specify the SECURITY_GROUP variable" 1>&2
fi

if [ ! "$SUBNET" ]
then
	echo "You need to specify the SUBNET variable" 1>&2
fi

if [ ! "$KEY_PAIR" ]
then
	echo "You need to specify the KEY_PAIR variable" 1>&2
fi

T="$(date +%s)"

echo "spawning $N ec2 instances"

for I in $(seq 1 "$N")
do
	echo "spawning instance $I"
	IID="hasura-cloud-benchmark-ec2-$I"

	aws --profile hasura ec2 run-instances \
	  --region ap-south-1 \
	  --image-id $AMI_NAME \
		--count 1 \
		--instance-type t2.large \
		--key-name $KEY_PAIR \
		--security-group-ids $SECURITY_GROUP \
		--subnet-id $SUBNET \
		| tee "logs/aws_ec2_logs_${T}_${I}.json"

	aws --profile=hasura \
		--region=ap-south-1 ec2 describe-instances \
		| jq -r '.Reservations | .[] | .Instances | .[] | { iid: .InstanceId, hostname: .NetworkInterfaces | .[] | .Association.PublicDnsName }' \
		> "logs/aws_rds_logs_${T}_${I}_ec2.txt"
done
