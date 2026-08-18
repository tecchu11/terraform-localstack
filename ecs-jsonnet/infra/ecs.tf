resource "aws_ecs_cluster" "main" {
  name = "app-${var.env}"
}

resource "aws_cloudwatch_log_group" "nginx" {
  name              = "/ecs/nginx-${var.env}"
  retention_in_days = 30
}

resource "aws_iam_role" "task_execution" {
  name = "nginx-${var.env}-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# jsonnet を plan フェーズで評価する。
# execRoleArn にリソース参照を渡すと data source の読み取りが apply まで
# 遅延され plan の可視性が落ちるため、プレースホルダを渡し
# 実際の値は下の execution_role_arn 属性で与える
data "external" "taskdef" {
  program = [
    "jsonnet",
    "--ext-str", "env=${var.env}",
    "--ext-str", "execRoleArn=placeholder",
    "${path.module}/../tf-view.jsonnet",
  ]
}

resource "aws_ecs_task_definition" "app" {
  family                   = data.external.taskdef.result.family
  network_mode             = data.external.taskdef.result.networkMode
  requires_compatibilities = jsondecode(data.external.taskdef.result.requiresCompatibilities)
  cpu                      = data.external.taskdef.result.cpu
  memory                   = data.external.taskdef.result.memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  container_definitions    = data.external.taskdef.result.containerDefinitions

  lifecycle {
    ignore_changes = [container_definitions]
  }

  depends_on = [aws_cloudwatch_log_group.nginx]
}

data "aws_ecs_task_definition" "latest" {
  task_definition = aws_ecs_task_definition.app.family
  depends_on      = [aws_ecs_task_definition.app]
}

resource "aws_ecs_service" "app" {
  name            = "nginx"
  cluster         = aws_ecs_cluster.main.id
  task_definition = data.aws_ecs_task_definition.latest.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    assign_public_ip = false
  }

  lifecycle {
    ignore_changes = [
      task_definition,
      desired_count,
      # 以下は Floci 互換のためだけの項目。DescribeServices がこれらを返さず
      # provider が空値として読み戻すため、毎回差分（scheduling_strategy は
      # 再作成）になる。実 AWS では不要
      scheduling_strategy,
      deployment_controller,
      platform_version,
      health_check_grace_period_seconds,
      tags,
    ]
  }
}

resource "aws_appautoscaling_target" "app" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  min_capacity       = 1
  max_capacity       = 10
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "nginx-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.app.service_namespace
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension
  resource_id        = aws_appautoscaling_target.app.resource_id

  target_tracking_scaling_policy_configuration {
    target_value = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
