# -----------------------------------------------------------------------------
# Northwind E-Commerce — Root Module
# 2-tier architecture: ALB + ASG (public) → RDS PostgreSQL (private)
# -----------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  public_subnets = {
    "public-1" = { cidr = "192.168.1.0/24", az = local.azs[0] }
    "public-2" = { cidr = "192.168.2.0/24", az = local.azs[1] }
  }

  private_subnets = {
    "private-1" = { cidr = "192.168.10.0/24", az = local.azs[0] }
    "private-2" = { cidr = "192.168.11.0/24", az = local.azs[1] }
  }
}

# --- Part 1: Networking ---

module "networking" {
  source = "./modules/networking"

  project_name    = var.project_name
  environment     = var.environment
  vpc_cidr        = var.vpc_cidr
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets
}

# --- Part 1: Database ---

module "database" {
  source = "./modules/database"

  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = module.networking.vpc_id
  vpc_cidr           = var.vpc_cidr
  private_subnet_ids = module.networking.private_subnet_ids
  db_username        = var.db_username
  db_password        = var.db_password
}

# --- Part 2: Compute (ALB + ASG) ---

module "compute" {
  source = "./modules/compute"

  project_name      = var.project_name
  environment       = var.environment
  vpc_id            = module.networking.vpc_id
  public_subnet_ids = module.networking.public_subnet_ids
}
