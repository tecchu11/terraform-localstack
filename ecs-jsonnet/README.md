# ECS + Terraform 構成の検証（Floci 上）

タスク定義の真実を jsonnet 1 箇所に置き、Terraform と外部デプロイ経路（CI）が
同じファイルを参照する構成が Terraform として成立するかを検証した記録。

検証環境: Floci 1.7.0 / Terraform 1.15.8 / hashicorp/aws 6.58.0 / hashicorp/external 2.4.1 / go-jsonnet 0.22.0

## 結論

**H1〜H6 すべて成立。** 縮退プランは不要だった。

| ID | 仮説 | 結果 |
|----|------|------|
| H1 | `data "external"` が plan で実行され、事前レンダリングなしに apply 一発 | ✅ |
| H2 | jsonnet 出力から `aws_ecs_task_definition` を作成できる | ✅ リビジョン 1 |
| H3 | `data "aws_ecs_task_definition"` で最新 active を解決しサービス作成 | ✅ |
| H4 | `aws_appautoscaling_target` / `_policy` を同一 apply 内で作成 | ✅ 多段不要 |
| H5 | 外部デプロイ後も `terraform plan` がクリーン | ✅ `No changes.` |
| H6 | overlay 切り替えに Terraform 出力が追随 | ✅ |

ただし Floci には 2 つの再現性のある忠実性ギャップがあり、それを回避するための
**Floci 専用の記述が `infra/ecs.tf` に 2 箇所ある**（後述）。実 AWS では不要。

## 使い方

```bash
docker run -d --name floci -p 4566:4566 \
  -v /var/run/docker.sock:/var/run/docker.sock -u root floci/floci:latest

export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=ap-northeast-1

terraform -chdir=infra init
terraform -chdir=infra apply -auto-approve
```

## Phase 0: Floci の API 対応状況

計画書のプローブは **6 個すべて成功**。追加で確認した周辺 API も全て成功した。

| API | 結果 |
|-----|------|
| `ecs:CreateCluster` / `RegisterTaskDefinition` / `CreateService` / `DescribeTaskDefinition`(family 名解決) / `DescribeServices` / `UpdateService` / `DeleteService` | OK |
| `application-autoscaling:RegisterScalableTarget` / `PutScalingPolicy` / `DescribeScalableTargets` / `DescribeScalingPolicies` | OK（CloudWatch アラームも自動生成される） |
| `iam:CreateRole` / `logs:CreateLogGroup` / `DescribeLogGroups` / `ecs:ListTagsForResource` / `sts:GetCallerIdentity` | OK |

`DescribeTaskDefinition` は family 名だけで最新 active リビジョンを解決できた
（リビジョン付きにフォールバックする必要はなかった）。

## Floci の忠実性ギャップ 2 件

### (1) `taskDefinition` を正規化せずエコーバックする → provider が panic

Floci は `CreateService` / `UpdateService` に渡された `taskDefinition` を
**そのまま保存して返す**。実 AWS は常に完全な ARN に正規化する。

計画書どおり `"${...family}:${...revision}"` を渡すと `DescribeServices` が
`nginx-prd:1` を返し、provider の ARN パーサが落ちる。

```
panic: runtime error: index out of range [1] with length 1
  ...ecs.familyAndRevisionFromTaskDefinitionARN(...) service.go:3893
Error: The terraform-provider-aws_v6.58.0_x5 plugin crashed!
```

さらに悪いことに、`CreateService` 自体は成功した後の read で落ちるため、
**Floci 側にサービスが残り Terraform state には入らない**（手動削除が必要）。

対処: 完全な ARN を渡す。実 AWS でも通用する書き方なので、これは常にこう書くのが良い。

```hcl
task_definition = data.aws_ecs_task_definition.latest.arn
```

CI 側も同様で、`register-task-definition` の戻り値 ARN をそのまま
`update-service` に渡す必要がある（`family:revision` を渡すと以後の plan が落ちる）。

### (2) `DescribeServices` が一部フィールドを返さない → 毎回再作成 plan

`schedulingStrategy` / `deploymentController` / `platformVersion` /
`deploymentConfiguration` が `null` で返る。実 AWS は必ず値を持つ。

結果、provider が `scheduling_strategy = ""` と読み戻し、
apply 直後の plan が `Plan: 1 to add, 0 to change, 1 to destroy`（強制再作成）になる。

対処: `infra/ecs.tf` の service の `ignore_changes` に Floci 専用項目を追加した。
コメントで実 AWS には不要である旨を明記してある。

> この 2 件は Floci の実装差であって、検証対象の設計の問題ではない。
> ただし (2) を潰さないと H5 の「plan がクリーン」を測れないため、切り分けとして必要だった。

## `tf-view.jsonnet` に必要だった調整

`data "external"` は「トップレベルがオブジェクトで全ての値が文字列」の JSON しか
受け取れない。計画書の案（`containerDefinitions` だけ潰す）は**そのまま動いた**が、
1 点だけ設計上の穴があったので拡張した。

### 見つかった穴: 最上位フィールドの手書きコピーが残っていた

計画書の `tf-view.jsonnet` は `family` / `cpu` / `memory` / `containerDefinitions`
しか出力しない。そのため `networkMode` と `requiresCompatibilities` が
`ecs.tf` に手書きで再掲されていた。

```hcl
network_mode             = "awsvpc"       # ← base.libsonnet と二重管理
requires_compatibilities = ["FARGATE"]    # ← 同上
```

**これは「`.tf` からコピーを無くす」という設計目的に対する取りこぼし。**
`base.libsonnet` の `networkMode` を変えても Terraform 側は追随せず、
Terraform が作る初回リビジョンと CI が作るリビジョンが食い違う。

対処: 配列も JSON 文字列として渡し、Terraform 側で `jsondecode()` する。
これで `map(string)` 制約を満たしたまま非スカラーを運べる。

```jsonnet
{
  family: td.family,
  cpu: td.cpu,
  memory: td.memory,
  networkMode: td.networkMode,
  requiresCompatibilities: std.manifestJsonEx(td.requiresCompatibilities, ''),
  containerDefinitions: std.manifestJsonEx(td.containerDefinitions, ''),
}
```

```hcl
network_mode             = data.external.taskdef.result.networkMode
requires_compatibilities = jsondecode(data.external.taskdef.result.requiresCompatibilities)
```

この形なら `ephemeral_storage` や `volume` など他の非スカラー項目も同じ手口で足せる。

## 各 Phase の実測

### Phase 1: jsonnet 層

`tf-view.jsonnet` の出力は全て文字列（`jq 'to_entries|all(.value|type=="string")'` が true）。
env=dev / env=prd で cpu・memory・image タグ・`extraEnv`・ロググループ名に差が出る。

### Phase 2: H1 / H2 / H3 / H4

plan 冒頭で `data.external` が **plan フェーズで読まれている**（apply 遅延ではない）:

```
data.external.taskdef: Reading...
data.external.taskdef: Read complete after 0s [id=-]
```

`container_definitions` は `(known after apply)` ではなく中身が展開されて見える:

```
+ container_definitions    = jsonencode(
      [
        + {
            + environment      = [
                + { + name = "ENV",                   + value = "prd" },
                + { + name = "NGINX_WORKER_PROCESSES", + value = "4"   },
              ]
            + essential        = true
            + image            = "nginx:1.27.4"
            + logConfiguration = { ... awslogs-group = "/ecs/nginx-prd" ... }
            + name             = "nginx"
            + portMappings     = [ + { + containerPort = 80, + protocol = "tcp" } ]
          },
      ]
  )
+ cpu                      = "512"
+ family                   = "nginx-prd"
+ memory                   = "1024"
```

**中間ファイルは一切生成されない**（`git status` がクリーンなまま）。

apply は 1 回・約 28 秒で 7 リソース。依存順が想定どおり直列化されている:

```
aws_ecs_task_definition.app: Creation complete after 0s [id=nginx-prd]
data.aws_ecs_task_definition.latest: Reading...
data.aws_ecs_task_definition.latest: Read complete after 0s [id=...task-definition/nginx-prd:1]
aws_ecs_cluster.main: Creation complete after 10s [id=...cluster/app-prd]
aws_ecs_service.app: Creation complete after 0s [id=...service/app-prd/nginx]
aws_appautoscaling_target.app: Creation complete after 0s [id=service/app-prd/nginx]
aws_appautoscaling_policy.cpu: Creation complete after 0s [id=nginx-cpu]
Apply complete! Resources: 7 added, 0 changed, 0 destroyed.
```

**H4 について**: `aws_appautoscaling_target` は `aws_ecs_service` の属性を参照するだけで
同一 apply 内に収まった。多段構築も `null_resource` も不要。

### Phase 3: H5（本命）

CI 相当として、同じ `taskdef.jsonnet` を評価し image タグだけ差し替えて登録・切り替え:

```
CI registered:      arn:aws:ecs:ap-northeast-1:000000000000:task-definition/nginx-prd:2
CI service now on:  arn:aws:ecs:ap-northeast-1:000000000000:task-definition/nginx-prd:2
```

その後の plan:

```
data.aws_ecs_task_definition.latest: Read complete after 0s [id=...task-definition/nginx-prd:2]

No changes. Your infrastructure matches the configuration.
```

state 上の内訳（`terraform state show`）:

| 対象 | 値 |
|------|-----|
| `data.aws_ecs_task_definition.latest.revision` | **2**（CI の結果に追随） |
| `aws_ecs_service.app.task_definition` | `...nginx-prd:2` |
| `aws_ecs_task_definition.app.revision` | **1**（Terraform 所有分は据え置き） |

Terraform 所有のリビジョン 1 と実稼働のリビジョン 2 が併存しても差分が出ない。
`.tf` は一切編集していない。

**追加検証**: `overlay/prd.libsonnet` の tag を書き換えて plan を実行しても
`No changes.` のまま（`ignore_changes` が効いている）。
設計意図どおりだが、裏を返すと **jsonnet の変更を Terraform は検知しない**。
リビジョンを進めるのは CI の責務であり、Terraform 側にドリフト検知は無い。

### Phase 4: H6

```
$ terraform plan -var env=dev
~ image    = "nginx:1.27.4" -> "nginx:latest"
~ cpu      = "512"  -> "256"
~ memory   = "1024" -> "512"
~ family   = "nginx-prd"     -> "nginx-dev"     # forces replacement
~ name     = "app-prd"       -> "app-dev"       # forces replacement (cluster)
~ name     = "/ecs/nginx-prd"-> "/ecs/nginx-dev"# forces replacement (log group)
~ name     = "nginx-prd-exec"-> "nginx-dev-exec"# forces replacement (iam role)
~ resource_id = "service/app-prd/nginx" -> "service/app-dev/nginx" # forces replacement
- name = "NGINX_WORKER_PROCESSES"   （prd 限定の環境変数が消える）
Plan: 7 to add, 0 to change, 7 to destroy.
```

`cpu` / `memory` が `ignore_changes` に入っているのに差分として出るのは、
`family` 変更でリソース自体が置換されるため。置換時は `ignore_changes` は効かない。

## 設計上気づいた点

1. **`ignore_changes` の `cpu` / `memory` は再考の余地がある。**
   `container_definitions` と違い cpu/memory は CI がリビジョンを登録し直せば
   タスク定義側で更新される一方、Terraform state は初回値のまま固定される。
   置換が起きた瞬間（family 変更など）に jsonnet の現在値へ飛ぶので、
   「普段は無視、置換時だけ追随」という挙動になる。意図的ならよいが直感には反する。

2. **`data.aws_ecs_task_definition.latest` は plan の度に外部状態を読む。**
   CI がデプロイした直後に plan すると service の `task_definition` が
   毎回新しい ARN に更新される。`ignore_changes = [task_definition]` があるので
   差分にはならないが、**`ignore_changes` を外すと plan の結果が
   「いつ実行したか」に依存する**（非決定的な plan）。この 2 つはセットで必要。

3. **`execRoleArn` プレースホルダは今の `tf-view.jsonnet` では露出しない。**
   `executionRoleArn` を view に含めていないため、`--ext-str execRoleArn=placeholder`
   の値は Terraform 側に一切漏れない。もし将来 view に含めるなら、
   リソース参照を渡すことになり `data "external"` の読み取りが apply まで遅延し、
   H1 の「plan で中身が見える」性質を失う。含めないままが良い。

4. **Terraform が作る初回リビジョンと CI が作るリビジョンは完全一致しない。**
   Terraform 経路は `tf-view.jsonnet`（射影）、CI 経路は `taskdef.jsonnet`（全体）を使う。
   view に載せ忘れたフィールドは Terraform 側のリビジョンから欠落する。
   上記の `networkMode` 問題が実例。**view はタスク定義の全フィールドを
   網羅するべきで、網羅を担保するテストがあると良い**
   （例: `taskdef.jsonnet` のキー集合と view のキー集合を比較する jsonnet アサーション）。

## 検証していないこと

計画書 8 節のとおり、実 Fargate でのタスク起動、`wait-for-service-stability`、
Auto Scaling の実挙動、`terraform destroy` 時のリビジョン残骸の扱いは対象外。
なお `terraform destroy` は Floci 上では 7 リソースすべてエラーなく削除できた。
