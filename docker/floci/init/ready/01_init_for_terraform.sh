#!/usr/bin/env bash
# Floci のイメージには awslocal / aws が無いため curl で直接叩く
set -euo pipefail

ENDPOINT="http://localhost:4566"
REGION="ap-northeast-1"
BUCKET="terraform-backend"
TABLE="terraform-locktable"

curl -fsS -o /dev/null -X PUT "${ENDPOINT}/${BUCKET}" \
  -H "Authorization: AWS4-HMAC-SHA256 Credential=test/00000000/${REGION}/s3/aws4_request" \
  || echo "[init] bucket ${BUCKET} already exists"

curl -fsS -o /dev/null -X POST "${ENDPOINT}/" \
  -H 'Content-Type: application/x-amz-json-1.0' \
  -H 'X-Amz-Target: DynamoDB_20120810.CreateTable' \
  -H "Authorization: AWS4-HMAC-SHA256 Credential=test/00000000/${REGION}/dynamodb/aws4_request" \
  -d "{
        \"TableName\": \"${TABLE}\",
        \"AttributeDefinitions\": [{\"AttributeName\": \"LockID\", \"AttributeType\": \"S\"}],
        \"KeySchema\": [{\"AttributeName\": \"LockID\", \"KeyType\": \"HASH\"}],
        \"ProvisionedThroughput\": {\"ReadCapacityUnits\": 1, \"WriteCapacityUnits\": 1}
      }" \
  || echo "[init] table ${TABLE} already exists"
