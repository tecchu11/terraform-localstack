# Terraform localstack sandbox

Provisioning aws resources to a local AWS emulator via terraform.

エミュレータは [Floci](https://hub.docker.com/r/floci/floci) を使う（`:4566` で
LocalStack 互換）。

```bash
docker compose up -d
```

| ディレクトリ | 内容 |
|-------------|------|
| `domain/` | S3 backend を使うメインのスタック |
| `module/` | 再利用モジュール |
| `docker/floci/` | Floci の永続化ボリュームと init hook |
| `ecs-jsonnet/` | ECS タスク定義を jsonnet 1 箇所で管理する構成の検証。[README](ecs-jsonnet/README.md) と `verify.sh` |
