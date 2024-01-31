variable "name" {
  type        = string
  description = "Name of security group."
}
variable "description" {
  type        = string
  description = "Security group description."
}
variable "vpc_id" {
  type        = string
  description = "VPC ID."
}
variable "tags" {
  type        = map(string)
  description = "Map of tags to assign to the resource."
  default     = {}
}

variable "ingress_rules" {
  type = map(object({
    cidr_ipv4                    = optional(string)
    cidr_ipv6                    = optional(string)
    description                  = string
    from_port                    = number
    ip_protocol                  = string
    prefix_list_id               = optional(string)
    referenced_security_group_id = optional(string)
    tags                         = optional(map(string))
    to_port                      = number
  }))
  description = "(Optional) Ingress rules for this security group. See https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule"
  default = {}
}

variable "egress_rules" {
  type = map(object({
    cidr_ipv4                    = optional(string)
    cidr_ipv6                    = optional(string)
    description                  = string
    from_port                    = number
    ip_protocol                  = string
    prefix_list_id               = optional(string)
    referenced_security_group_id = optional(string)
    tags                         = optional(map(string))
    to_port                      = number
  }))
  description = "(Optional) Egress rules for this security group. See https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule"
  default = {}
}
