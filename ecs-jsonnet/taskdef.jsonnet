local env = std.extVar('env');
local execRoleArn = std.extVar('execRoleArn');
local base = import 'base.libsonnet';

local defaults = {
  env: env,
  execRoleArn: execRoleArn,
  tag: 'latest',
  cpu: '256',
  memory: '512',
  extraEnv: [],
  sidecars: [],
};

local overlays = {
  dev: import 'overlay/dev.libsonnet',
  prd: import 'overlay/prd.libsonnet',
};

base(defaults + overlays[env])
