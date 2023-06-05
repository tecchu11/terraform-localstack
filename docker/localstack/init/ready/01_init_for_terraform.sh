#!/bin/bash

awslocal s3 mb s3://terraform-backend

awslocal dynamodb create-table \
  --table-name terraform-locktable \
  --attribute-definitions \
  AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1 \
  --region ap-northeast-1
