variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the ALB and ASG"
  type        = list(string)
}

variable "rds_endpoint" {
  description = "RDS endpoint passed to instances via user data"
  type        = string
  sensitive   = true
}

variable "asg_min" {
  description = "Minimum number of instances in the ASG"
  type        = number
  default     = 1
}

variable "asg_max" {
  description = "Maximum number of instances in the ASG"
  type        = number
  default     = 3
}
