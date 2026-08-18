// data "external" は map(string) しか返せない。
// taskdef.jsonnet の全トップレベル項目を機械的に写し、文字列でない値は
// JSON 文字列に潰す。Terraform 側で jsondecode() すれば元の型に戻せる。
// 手で列挙しないので、項目の載せ忘れが起こらない。
local td = import 'taskdef.jsonnet';
{
  [k]: if std.isString(td[k]) then td[k] else std.manifestJsonEx(td[k], '')
  for k in std.objectFields(td)
}
