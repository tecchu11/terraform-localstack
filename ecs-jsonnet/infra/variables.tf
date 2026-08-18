variable "env" {
  type    = string
  default = "prd"
}

variable "subnet_ids" {
  type    = list(string)
  default = []
}
