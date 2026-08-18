#!/usr/bin/env bash
# Terraform の S3 backend 用リソースを作る。
#
# LocalStack と違い Floci のイメージには awslocal / aws / python が入っていない
# （bash と curl のみ）。そのため AWS CLI ではなく生の API を curl で叩いている。
# Floci は署名を検証しないので Authorization ヘッダはダミーで良い。
set -euo pipefail

ENDPOINT="http://localhost:4566"
REGION="ap-northeast-1"
BUCKET="terraform-backend"
TABLE="terraform-locktable"

# 永続化モードでの再起動時は既に存在するため、いずれも失敗させない
echo "[init] creating s3 bucket: ${BUCKET}"
curl -fsS -o /dev/null -X PUT "${ENDPOINT}/${BUCKET}" \
  -H "Authorization: AWS4-HMAC-SHA256 Credential=test/00000000/${REGION}/s3/aws4_request" \
  || echo "[init] bucket already exists or creation skipped"

echo "[init] creating dynamodb table: ${TABLE}"
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
  || echo "[init] table already exists or creation skipped"

echo "[init] done"
