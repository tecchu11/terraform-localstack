module "sg" {
  source          = "../module/sg"
  description     = "sample sg"
  name            = "sample-sg"
  vpc_id          = "sample-vpc-id"
  attache_ingress = true
  ingress_rules = {
    sample = {
      cidr_ipv4   = "0.0.0.0/0"
      description = "sample sg rule"
      from_port   = 443
      ip_protocol = "tcp"
      to_port     = 8080
    }
  }
  egress_rules = {
    full_open = {
      cidr_ipv4   = "0.0.0.0/0"
      description = "full open"
      from_port   = 0
      ip_protocol = "-1"
      to_port     = 0
    }
  }
}
