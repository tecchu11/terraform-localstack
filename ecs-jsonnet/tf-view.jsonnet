// data "external" は map(string) しか返せないため、
// スカラーはそのまま、配列/オブジェクトは JSON 文字列に潰して渡す。
// Terraform 側で jsondecode() すれば元の型に戻せる。
local td = import 'taskdef.jsonnet';
{
  family: td.family,
  cpu: td.cpu,
  memory: td.memory,
  networkMode: td.networkMode,
  requiresCompatibilities: std.manifestJsonEx(td.requiresCompatibilities, ''),
  containerDefinitions: std.manifestJsonEx(td.containerDefinitions, ''),
}
