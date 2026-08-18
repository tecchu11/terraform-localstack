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

ただし Floci には 3 つの再現性のある忠実性ギャップがあり、うち 2 つを回避するための
**Floci 専用の記述が `infra/ecs.tf` にある**（後述）。実 AWS では不要。

## 再検証のしかた

必要なもの: Docker / Terraform 1.15.8 / `jsonnet` / AWS CLI v2 / `jq`

```bash
# repository ルートで
docker compose up -d          # Floci が :4566 で起動する

./ecs-jsonnet/verify.sh       # H1〜H6 を通しで検証 (18 チェック)
```

`verify.sh` は冪等で、実行のたびに `terraform destroy` と前回のリビジョン掃除から
始まるので何度でも回せる。全て成功すると `18 passed, 0 failed` で終わる。
失敗したチェックがある場合は plan / apply の生ログのパスを表示して exit 1 する。

手で触りたい場合:

```bash
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=ap-northeast-1

terraform -chdir=ecs-jsonnet/infra init
terraform -chdir=ecs-jsonnet/infra apply -auto-approve
terraform -chdir=ecs-jsonnet/infra destroy -auto-approve   # 後片付け
```

state はこのディレクトリ配下のローカルファイル。`domain/` と違い S3 backend は
使っていない（検証を自己完結させるため）。

## Phase 0: Floci の API 対応状況

計画書のプローブは **6 個すべて成功**。追加で確認した周辺 API も全て成功した。

| API | 結果 |
|-----|------|
| `ecs:CreateCluster` / `RegisterTaskDefinition` / `CreateService` / `DescribeTaskDefinition`(family 名解決) / `DescribeServices` / `UpdateService` / `DeleteService` | OK |
| `application-autoscaling:RegisterScalableTarget` / `PutScalingPolicy` / `DescribeScalableTargets` / `DescribeScalingPolicies` | OK（CloudWatch アラームも自動生成される） |
| `iam:CreateRole` / `logs:CreateLogGroup` / `DescribeLogGroups` / `ecs:ListTagsForResource` / `sts:GetCallerIdentity` | OK |

`DescribeTaskDefinition` は family 名だけで最新 active リビジョンを解決できた
（リビジョン付きにフォールバックする必要はなかった）。

## Floci の忠実性ギャップ 3 件

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

### (3) `containerDefinitions` を round-trip しない → H5 の測定を歪める

`RegisterTaskDefinition` に渡した内容が `DescribeTaskDefinition` でそのまま返らない。
**`logConfiguration` が丸ごと消え、`portMappings` に `hostPort: 0` が生える。**

| 送った内容 | 返ってくる内容 |
|-----------|---------------|
| `logConfiguration: {logDriver: awslogs, options: {...}}` | （消える） |
| `portMappings: [{containerPort: 80, protocol: tcp}]` | `[{containerPort: 80, hostPort: 0, protocol: tcp}]` |

結果、`ignore_changes` から `container_definitions` を外すと
**初回 apply 直後の plan からタスク定義が再作成対象になる**（`Plan: 1 to add, 1 to destroy`）。

これは H5 の測定にとって重要な限界で、正直に書いておく。
`ignore_changes = [container_definitions]` は本来「CI がリビジョンを持つ」という
設計意図のために置いているものだが、**Floci 上ではこのエミュレータのバグも同時に
隠してしまう**。したがって「H5 の plan がクリーンなのは設計が成立しているからだ」と
Floci だけで言い切ることはできない。実 AWS での確認が必要。

## `tf-view.jsonnet` に必要だった調整

`data "external"` は「トップレベルがオブジェクトで全ての値が文字列」の JSON しか
受け取れない。計画書の案（`containerDefinitions` だけ潰す）はそのまま動いたが、
項目を手で列挙する形だったため、次の穴があった。

### 見つかった穴: 手で列挙すると載せ忘れに気づけない

計画書の `tf-view.jsonnet` は `family` / `cpu` / `memory` / `containerDefinitions`
しか出力しない。そのため `networkMode` と `requiresCompatibilities` が
`ecs.tf` に手書きで再掲されていた。

```hcl
network_mode             = "awsvpc"       # ← base.libsonnet と二重管理
requires_compatibilities = ["FARGATE"]    # ← 同上
```

「`.tf` からコピーを無くす」という設計目的に対する取りこぼしである。しかも
載せ忘れても何も起きないので、指摘されるまで気づけない。

### 対処: view を手で書かず `taskdef.jsonnet` から機械導出する

文字列はそのまま、それ以外は `std.manifestJsonEx` で JSON 文字列に潰す。
これで `map(string)` 制約を満たしたまま非スカラーを運べる。
列挙しないので、項目の載せ忘れという事象自体が起こらない。

```jsonnet
local td = import 'taskdef.jsonnet';
{
  [k]: if std.isString(td[k]) then td[k] else std.manifestJsonEx(td[k], '')
  for k in std.objectFields(td)
}
```

Terraform 側は必要なキーを名前で読み、非スカラーは `jsondecode()` で戻す。

```hcl
network_mode             = data.external.taskdef.result.networkMode
requires_compatibilities = jsondecode(data.external.taskdef.result.requiresCompatibilities)
```

型ごとの変換結果は次のとおり。

| `taskdef.jsonnet` の値 | view の値 |
|---|---|
| `"awsvpc"` | `"awsvpc"` |
| `21` | `"21"` |
| `true` | `"true"` |
| `null` | `"null"` |
| `["FARGATE"]` | `"[\n\"FARGATE\"\n]"` |
| オブジェクト | JSON 文字列 |

`ephemeral_storage` や `volume` を `base.libsonnet` に足した場合も、view には
自動で載る。ただし **`ecs.tf` に対応する属性を書き足す作業は手作業のまま残る**
（後述の「設計上気づいた点」を参照）。

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

### 補足: この `No changes.` が保証しないこと

H5 は「外部デプロイによって Terraform 側が乱されないこと」であり、それは成立している。
一方で、これは「動いているリビジョンが jsonnet と一致していること」の保証ではない。
計画書が「`ignore_changes` は依然として必要」と書いているとおり、Terraform 側に
ドリフト検知は無い。念のため実測した。

CI が jsonnet と無関係な定義でリビジョンを登録しても plan はクリーンなままである。

```bash
# CI 相当が全く別物を登録し、service をそれに向ける
#   image: httpd:2.4-TOTALLY-DIFFERENT / cpu: 4096 / 想定外の sidecar 追加
$ aws ecs register-task-definition --cli-input-json file://divergent.json
arn:aws:ecs:...:task-definition/nginx-prd:3
$ aws ecs update-service --cluster app-prd --service nginx --task-definition nginx-prd:3

$ terraform plan
data.aws_ecs_task_definition.latest: Read complete after 0s [id=...nginx-prd:3]
No changes. Your infrastructure matches the configuration.
```

`aws_ecs_task_definition.app` はリビジョン 1 に固定されており、CI が作るリビジョンは
それを変更しないためである。

これは設計の欠陥ではなく、計画書が前提として書いていることの帰結である。
この構成が狙っているのは「`.tf` にコンテナ定義のコピーを持たないこと」であり、
それは達成されている。運用上の注意として、**Terraform の plan は
デプロイ内容の正しさを見る手段にはならない**（それは CI 側の責務になる）。

### Phase 4: H6

`ignore_changes = all` は「更新」にしか効かず「作成」には効かないので、
env ごとに state を分ければ overlay の値はそのまま反映される（実運用と同じ形）。
`verify.sh` は `dev` workspace で apply して、出来たタスク定義を直接確認している。

| | prd | dev |
|---|---|---|
| cpu / memory | 512 / 1024 | 256 / 512 |
| image | `nginx:1.27.4` | `nginx:latest` |
| `NGINX_WORKER_PROCESSES` | あり | 無し |
| cluster | `app-prd` | `app-dev` |

## 設計上気づいた点

1. **Terraform が初回リビジョンを作ることは、この構成の前提そのもの。**
   新規環境ではタスク定義が 1 つも無く `data.aws_ecs_task_definition.latest` が
   解決できないため、サービスも Auto Scaling も作れない。Terraform が
   リビジョン 1 を登録することで、初回構築が 1 回の apply で完結する（H1 / H4）。
   その代わり state はリビジョン 1 に固定され、実稼働のリビジョン N とは一致しない。
   これは計画書が想定している状態であり、無視される対象が「手書きコピー」ではなく
   「同一ソースの射影」になっている点が要点。

2. **view の `executionRoleArn` は読んではいけない。**
   機械導出にしたことで `executionRoleArn` も view に載るようになったが、
   その値は `--ext-str execRoleArn=placeholder` で渡したプレースホルダである。
   `ecs.tf` は意図的にこのキーを読まず、`aws_iam_role.task_execution.arn` を使う。

   実際のロール ARN を jsonnet に渡そうとすると、`data "external"` の `program` に
   リソース参照を書くことになり、data source の読み取りが apply まで遅延する。
   すると plan で `container_definitions` の中身が見えなくなり、H1 の性質を失う。
   プレースホルダを渡して Terraform 側で実値を与える現在の形が必要。

3. **`ecs.tf` に属性を書き足す作業は手作業のまま残る。**
   view の載せ忘れは機械導出で構造的に解消したが、`ecs.tf` の
   `aws_ecs_task_definition` は属性を一つずつ書いて view から読んでいる。
   `taskdef.jsonnet` に項目を足しても、対応する属性を書かなければ Terraform 側の
   リビジョンには入らない。

   ただし影響は限定的で、`ignore_changes = all` のため **既存環境では属性を
   書いても書かなくても Terraform は何もしない**。差が出るのは新規環境の初回
   リビジョンだけで、それも CI が最初にデプロイした時点で置き換わる。

   `lifecycle.precondition` で検出する案も検討したが採用しなかった。上記のとおり
   既存環境では対応しても結果が変わらないのに、全環境の plan を失敗させることに
   なり、誤警報になるため。

## 検証していないこと

計画書 8 節のとおり、実 Fargate でのタスク起動、`wait-for-service-stability`、
Auto Scaling の実挙動、`terraform destroy` 時のリビジョン残骸の扱いは対象外。
なお `terraform destroy` は Floci 上では 7 リソースすべてエラーなく削除できた。
