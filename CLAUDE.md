# CLAUDE.md - TrueBit (Northwind DevOps Assessment)

## Project Overview

Terraform-based 2-tier AWS architecture for Northwind e-commerce — ALB/ASG public tier + RDS PostgreSQL private tier, with a smart CI/CD pipeline.

## Tech Stack

| Component | Tech Stack | Purpose |
|-----------|------------|---------|
| Infrastructure | Terraform ~> 1.5 | IaC for all AWS resources |
| Networking | AWS VPC, IGW, Subnets | Public/private network isolation |
| Database | RDS PostgreSQL 16.4 | Data tier in private subnets |
| Compute | ALB + ASG + Launch Template | Web tier with auto-scaling |
| CI/CD | GitHub Actions | Smart conditional pipeline |

## Project Structure

```
truebit/
├── main.tf                          # Root module — wires networking, database, compute
├── variables.tf                     # Root input variables
├── outputs.tf                       # Root outputs (ALB DNS, RDS endpoint)
├── providers.tf                     # AWS provider config
├── terraform.tfvars.example         # Example variable values
├── modules/
│   ├── networking/                  # VPC, subnets, IGW, route tables
│   ├── database/                    # RDS PostgreSQL, security group, subnet group
│   └── compute/                     # ALB (community module), launch template, ASG
└── .github/workflows/
    └── pipeline.yml                 # Smart pipeline with matrix execution
```

## Quick Start

```bash
cd truebit
cp terraform.tfvars.example terraform.tfvars  # Edit with real values
terraform init
terraform plan
terraform apply
```
