## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_egress_rule.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_description"></a> [description](#input\_description) | Security group description. | `string` | n/a | yes |
| <a name="input_egress_rules"></a> [egress\_rules](#input\_egress\_rules) | (Optional) Egress rules for this security group. See https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule | <pre>map(object({<br>    cidr_ipv4                    = optional(string)<br>    cidr_ipv6                    = optional(string)<br>    description                  = string<br>    from_port                    = number<br>    ip_protocol                  = string<br>    prefix_list_id               = optional(string)<br>    referenced_security_group_id = optional(string)<br>    tags                         = optional(map(string))<br>    to_port                      = number<br>  }))</pre> | `{}` | no |
| <a name="input_ingress_rules"></a> [ingress\_rules](#input\_ingress\_rules) | (Optional) Ingress rules for this security group. See https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule | <pre>map(object({<br>    cidr_ipv4                    = optional(string)<br>    cidr_ipv6                    = optional(string)<br>    description                  = string<br>    from_port                    = number<br>    ip_protocol                  = string<br>    prefix_list_id               = optional(string)<br>    referenced_security_group_id = optional(string)<br>    tags                         = optional(map(string))<br>    to_port                      = number<br>  }))</pre> | `{}` | no |
| <a name="input_name"></a> [name](#input\_name) | Name of security group. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Map of tags to assign to the resource. | `map(string)` | `{}` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | VPC ID. | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_security_group_id"></a> [security\_group\_id](#output\_security\_group\_id) | Security group id. |
