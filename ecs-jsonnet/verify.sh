#!/usr/bin/env bash
#
# H1〜H6 を Floci 上で通しで検証する。
#
#   docker compose up -d          # repository ルートで
#   ./ecs-jsonnet/verify.sh
#
# 冪等。実行のたびに terraform destroy から始めるので何度でも回せる。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="${SCRIPT_DIR}/infra"
TF="${TF:-terraform}"
ENDPOINT="${ENDPOINT:-http://localhost:4566}"
AWS_CLI="aws --endpoint-url=${ENDPOINT}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
RESULTS=()

check() { # check <id> <description> <0|1 as command result>
  local id="$1" desc="$2"
  if [ "$3" -eq 0 ]; then
    printf '  \033[32mPASS\033[0m  %-4s %s\n' "$id" "$desc"
    RESULTS+=("PASS $id $desc"); PASS=$((PASS + 1))
  else
    printf '  \033[31mFAIL\033[0m  %-4s %s\n' "$id" "$desc"
    RESULTS+=("FAIL $id $desc"); FAIL=$((FAIL + 1))
  fi
}

section() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- 前提確認
section "前提確認"
missing=0
for bin in "$TF" jsonnet aws jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "  ERROR: '$bin' が PATH にありません" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1

if ! curl -fsS --max-time 5 "${ENDPOINT}/_floci/health" >/dev/null 2>&1; then
  echo "  ERROR: ${ENDPOINT} に Floci が居ません。repository ルートで 'docker compose up -d' を実行してください" >&2
  exit 1
fi
echo "  Floci $(curl -fsS "${ENDPOINT}/_floci/info" | jq -r .version) / $("$TF" version | head -1) / jsonnet $(jsonnet --version | grep -oE 'v[0-9.]+')"

# ---------------------------------------------- 前回の残骸を消してから始める
section "初期化 (前回の残骸を destroy)"
"$TF" -chdir="$INFRA" init -input=false -no-color >/dev/null 2>&1
if [ -f "${INFRA}/terraform.tfstate" ]; then
  "$TF" -chdir="$INFRA" destroy -auto-approve -no-color >/dev/null 2>&1
fi
rm -f "${INFRA}/terraform.tfstate" "${INFRA}/terraform.tfstate.backup"

# サービスが残っていると再作成できないので念のため掃除
$AWS_CLI ecs delete-service --cluster app-prd --service nginx --force >/dev/null 2>&1

# 前回の実行が残した ACTIVE リビジョン (特に CI 相当が登録した分) を落とす。
# これを残すと data.aws_ecs_task_definition.latest が前回の遺物を拾い、
# 実行ごとに結果が変わる。
for family in nginx-prd nginx-dev; do
  for arn in $($AWS_CLI ecs list-task-definitions \
                 --family-prefix "$family" --status ACTIVE 2>/dev/null \
               | jq -r '.taskDefinitionArns[]? // empty'); do
    $AWS_CLI ecs deregister-task-definition --task-definition "$arn" >/dev/null 2>&1
  done
done
echo "  done"

# ------------------------------------------------------ Phase 1: jsonnet 層
section "Phase 1: jsonnet 層"
for env in dev prd; do
  jsonnet --ext-str env="$env" --ext-str execRoleArn=dummy \
    "${SCRIPT_DIR}/tf-view.jsonnet" > "${WORK}/view-${env}.json" 2>"${WORK}/view-${env}.err"
  jq -e 'to_entries | all(.value | type == "string")' "${WORK}/view-${env}.json" >/dev/null 2>&1
  check "-" "tf-view.jsonnet (env=${env}) の値が全て文字列 (map(string) 制約)" $?
done
! diff -q "${WORK}/view-dev.json" "${WORK}/view-prd.json" >/dev/null 2>&1
check "H6" "env=dev と env=prd で tf-view の出力に差が出る" $?

# ------------------------------------- Phase 2: plan (H1) / apply (H2/3/4)
section "Phase 2: plan と apply"
BEFORE="$(find "$SCRIPT_DIR" -type f -not -path '*/.terraform/*' -not -name 'terraform.tfstate*' | sort)"
"$TF" -chdir="$INFRA" plan -no-color > "${WORK}/plan2.txt" 2>&1
grep -q 'data.external.taskdef: Read complete' "${WORK}/plan2.txt"
check "H1" "data \"external\" が plan フェーズで読まれる" $?

grep -q 'nginx:1.27.4' "${WORK}/plan2.txt"
check "H1" "container_definitions の中身が plan に展開される ((known after apply) でない)" $?

AFTER="$(find "$SCRIPT_DIR" -type f -not -path '*/.terraform/*' -not -name 'terraform.tfstate*' | sort)"
[ "$BEFORE" = "$AFTER" ]
check "H1" "中間ファイルが生成されない" $?

"$TF" -chdir="$INFRA" apply -auto-approve -no-color > "${WORK}/apply.txt" 2>&1
grep -qE 'Apply complete! Resources: 7 added' "${WORK}/apply.txt"
check "H1" "apply 一発で 7 リソース全て作成される (多段不要)" $?

grep -q 'aws_ecs_task_definition.app: Creation complete' "${WORK}/apply.txt"
check "H2" "aws_ecs_task_definition が作成される" $?

grep -q 'aws_ecs_service.app: Creation complete' "${WORK}/apply.txt"
check "H3" "aws_ecs_service が作成される" $?

grep -q 'aws_appautoscaling_target.app: Creation complete' "${WORK}/apply.txt" &&
  grep -q 'aws_appautoscaling_policy.cpu: Creation complete' "${WORK}/apply.txt"
check "H4" "appautoscaling target/policy が同一 apply 内で作成される" $?

"$TF" -chdir="$INFRA" plan -no-color > "${WORK}/plan2b.txt" 2>&1
grep -q 'No changes' "${WORK}/plan2b.txt"
check "-" "apply 直後の plan がクリーン (冪等)" $?

# ------------------------------------------------ Phase 3: 腐敗耐性 (H5)
section "Phase 3: 外部デプロイ後も plan がクリーンか (H5)"
ROLE="$("$TF" -chdir="$INFRA" output -raw exec_role_arn)"

# CI 相当: Terraform と同じ jsonnet を評価し、image タグだけ差し替えて登録する
jsonnet --ext-str env=prd --ext-str execRoleArn="$ROLE" "${SCRIPT_DIR}/taskdef.jsonnet" \
  | jq '(.containerDefinitions[] | select(.name == "nginx") | .image) = "nginx:1.27.5"' \
  > "${WORK}/taskdef-v2.json"

# Terraform が作ったリビジョン番号。Floci は destroy 後もリビジョンを
# 採番し続けるため、2 固定ではなく実測値との相対で検証する
TF_REV="$("$TF" -chdir="$INFRA" state show aws_ecs_task_definition.app \
  | awk '$1 == "revision" { print $3 }')"

NEW_ARN="$($AWS_CLI ecs register-task-definition \
  --cli-input-json "file://${WORK}/taskdef-v2.json" \
  | jq -r '.taskDefinition.taskDefinitionArn')"
NEW_REV="${NEW_ARN##*:}"
echo "  Terraform が作ったリビジョン: ${TF_REV} / CI が登録したリビジョン: ${NEW_REV}"

# 注: family:revision 形式ではなく完全な ARN を渡すこと。
# Floci は渡された文字列をそのまま返すため、family:revision だと
# 以後の terraform plan で AWS provider の ARN パーサが panic する。
$AWS_CLI ecs update-service --cluster app-prd --service nginx \
  --task-definition "$NEW_ARN" >/dev/null

[ "$NEW_REV" -gt "$TF_REV" ]
check "H5" "外部 (CI 相当) が新しいリビジョン (${TF_REV} -> ${NEW_REV}) を登録できる" $?

"$TF" -chdir="$INFRA" plan -no-color > "${WORK}/plan3.txt" 2>&1
grep -q 'No changes' "${WORK}/plan3.txt"
check "H5" "外部デプロイ後の terraform plan が 'No changes'" $?

grep -q "data.aws_ecs_task_definition.latest: Read complete.*nginx-prd:${NEW_REV}" "${WORK}/plan3.txt"
check "H5" "data.aws_ecs_task_definition.latest がリビジョン ${NEW_REV} を解決する" $?

# jsonnet を書き換えても plan は汚れない (ignore_changes が効いている)
cp "${SCRIPT_DIR}/overlay/prd.libsonnet" "${WORK}/prd.bak"
sed -i.bak "s/tag: '1.27.4'/tag: '1.27.5'/" "${SCRIPT_DIR}/overlay/prd.libsonnet"
"$TF" -chdir="$INFRA" plan -no-color 2>&1 | grep -q 'No changes'
result=$?
cp "${WORK}/prd.bak" "${SCRIPT_DIR}/overlay/prd.libsonnet"
rm -f "${SCRIPT_DIR}/overlay/prd.libsonnet.bak"
check "H5" "jsonnet ソースを書き換えても plan がクリーン" $result

# --------------------------------------------- Phase 4: overlay 切替 (H6)
section "Phase 4: overlay 切り替え (H6)"
"$TF" -chdir="$INFRA" plan -var env=dev -no-color > "${WORK}/plan4.txt" 2>&1
grep -q '"512" -> "256"' "${WORK}/plan4.txt" && grep -q '"1024" -> "512"' "${WORK}/plan4.txt"
check "H6" "cpu / memory が dev の値に変わる" $?

grep -q '"nginx:1.27.4" -> "nginx:latest"' "${WORK}/plan4.txt"
check "H6" "image タグが dev の値に変わる" $?

grep -q '"nginx-prd" -> "nginx-dev"' "${WORK}/plan4.txt" &&
  grep -q '"app-prd" -> "app-dev"' "${WORK}/plan4.txt" &&
  grep -q '"/ecs/nginx-prd" -> "/ecs/nginx-dev"' "${WORK}/plan4.txt"
check "H6" "family / cluster / log group 名が -dev に変わる" $?

# --------------------------------------------------------------- まとめ
section "結果"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo
  printf '%s\n' "${RESULTS[@]}" | grep '^FAIL' | sed 's/^/  /'
  echo
  trap - EXIT
  echo "  plan / apply の生ログを残しました: ${WORK}"
  exit 1
fi
echo "  全て成立。terraform -chdir=ecs-jsonnet/infra destroy で後片付けできます。"
