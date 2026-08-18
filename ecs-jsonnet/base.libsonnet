function(p) {
  family: 'nginx-' + p.env,
  networkMode: 'awsvpc',
  requiresCompatibilities: ['FARGATE'],
  cpu: p.cpu,
  memory: p.memory,
  executionRoleArn: p.execRoleArn,
  containerDefinitions: [{
    name: 'nginx',
    image: 'nginx:' + p.tag,
    essential: true,
    portMappings: [{ containerPort: 80, protocol: 'tcp' }],
    environment: [{ name: 'ENV', value: p.env }] + p.extraEnv,
    logConfiguration: {
      logDriver: 'awslogs',
      options: {
        'awslogs-group': '/ecs/nginx-' + p.env,
        'awslogs-region': 'ap-northeast-1',
        'awslogs-stream-prefix': 'nginx',
      },
    },
  }] + p.sidecars,
}
