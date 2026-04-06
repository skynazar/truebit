# Northwind Infrastructure — Architecture & Best Practices

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Network Architecture (Part 1)](#network-architecture)
3. [Database Tier (Part 1)](#database-tier)
4. [Application Tier (Part 2)](#application-tier)
5. [CI/CD Pipeline (Part 3)](#cicd-pipeline)
6. [Security Best Practices](#security-best-practices)
7. [Terraform Best Practices](#terraform-best-practices)
8. [Operational Runbook](#operational-runbook)

---

## Architecture Overview

Northwind uses a classic **2-tier architecture** on AWS — a public-facing web tier behind an Application Load Balancer, backed by a PostgreSQL database isolated in private subnets. All infrastructure is defined as code using Terraform with a modular, DRY structure.

```
                          ┌─────────────────────────────────────────────────────────────┐
                          │                     AWS Region (us-east-1)                  │
                          │                                                             │
                          │   ┌─────────────────────────────────────────────────────┐   │
                          │   │              VPC  192.168.0.0/16                     │   │
                          │   │                                                     │   │
    ┌──────────┐          │   │   ┌─────────────────────────────────────────────┐   │   │
    │          │          │   │   │          PUBLIC  TIER                       │   │   │
    │ Internet │────────────────▶│   ┌──────────────────────────────────────┐   │   │   │
    │          │          │   │   │   │     Application Load Balancer       │   │   │   │
    └──────────┘          │   │   │   │          (HTTP :80)                 │   │   │   │
         │                │   │   │   └──────────┬───────────┬─────────────┘   │   │   │
         │                │   │   │              │           │                 │   │   │
         ▼                │   │   │   ┌──────────▼──┐  ┌────▼───────────┐     │   │   │
    ┌──────────┐          │   │   │   │  AZ-a       │  │  AZ-b          │     │   │   │
    │ Internet │          │   │   │   │ 192.168.1.0 │  │ 192.168.2.0   │     │   │   │
    │ Gateway  │          │   │   │   │  ┌───────┐  │  │  ┌───────┐    │     │   │   │
    └──────────┘          │   │   │   │  │ nginx │  │  │  │ nginx │    │     │   │   │
                          │   │   │   │  │t3.micro│ │  │  │t3.micro│   │     │   │   │
                          │   │   │   │  └───────┘  │  │  └───────┘    │     │   │   │
                          │   │   │   └─────────────┘  └───────────────┘     │   │   │
                          │   │   │         Auto Scaling Group (1–3)         │   │   │
                          │   │   └─────────────────────────────────────────────┘   │   │
                          │   │                        │                             │   │
                          │   │                        │ port 5432 (VPC CIDR only)   │   │
                          │   │                        ▼                             │   │
                          │   │   ┌─────────────────────────────────────────────┐   │   │
                          │   │   │          PRIVATE  TIER                      │   │   │
                          │   │   │                                             │   │   │
                          │   │   │   ┌─────────────┐  ┌───────────────┐       │   │   │
                          │   │   │   │  AZ-a       │  │  AZ-b         │       │   │   │
                          │   │   │   │ 192.168.10.0│  │ 192.168.11.0 │       │   │   │
                          │   │   │   │  ┌───────┐  │  │               │       │   │   │
                          │   │   │   │  │  RDS  │  │  │  (standby)   │       │   │   │
                          │   │   │   │  │ PgSQL │  │  │               │       │   │   │
                          │   │   │   │  └───────┘  │  │               │       │   │   │
                          │   │   │   └─────────────┘  └───────────────┘       │   │   │
                          │   │   │       DB Subnet Group (Multi-AZ ready)     │   │   │
                          │   │   └─────────────────────────────────────────────┘   │   │
                          │   │                                                     │   │
                          │   └─────────────────────────────────────────────────────┘   │
                          │                                                             │
                          └─────────────────────────────────────────────────────────────┘
```

### Design Decisions

| Decision | Rationale |
|----------|-----------|
| 2 AZs | High availability without cost overhead of 3-AZ for a startup |
| Public subnets for compute | Nginx serves static content directly; NAT Gateway avoided to reduce cost |
| Private subnets for RDS | Database is never internet-reachable — defense in depth |
| Community ALB module | Battle-tested, maintained by HashiCorp; avoids reinventing listener/TG wiring |
| Single VPC | Startup scale — no need for multi-VPC or Transit Gateway yet |

---

## Network Architecture

### VPC & Subnet Layout

```
VPC: 192.168.0.0/16  (65,536 IPs)
│
├── Public Subnets (internet-routable via IGW)
│   ├── 192.168.1.0/24   AZ-a   (254 usable IPs)
│   └── 192.168.2.0/24   AZ-b   (254 usable IPs)
│
└── Private Subnets (no internet route)
    ├── 192.168.10.0/24   AZ-a   (254 usable IPs)
    └── 192.168.11.0/24   AZ-b   (254 usable IPs)
```

### Routing Model

```
                    ┌──────────────┐
                    │   Internet   │
                    │   Gateway    │
                    └──────┬───────┘
                           │
              ┌────────────▼────────────┐
              │   Public Route Table    │
              │  0.0.0.0/0 → IGW       │
              │  192.168.0.0/16 → local │
              └────────────┬────────────┘
                           │
                ┌──────────┴──────────┐
                │                     │
        ┌───────▼──────┐     ┌───────▼──────┐
        │  Public-1    │     │  Public-2    │
        │  AZ-a        │     │  AZ-b        │
        └──────────────┘     └──────────────┘


              ┌─────────────────────────┐
              │  Default Route Table    │
              │  192.168.0.0/16 → local │
              │  (no 0.0.0.0/0 route)   │   ← Private subnets have NO
              └────────────┬────────────┘     internet egress by default
                           │
                ┌──────────┴──────────┐
                │                     │
        ┌───────▼──────┐     ┌───────▼──────┐
        │  Private-1   │     │  Private-2   │
        │  AZ-a        │     │  AZ-b        │
        └──────────────┘     └──────────────┘
```

**Key points:**
- Only the public route table has a `0.0.0.0/0 → IGW` route
- Private subnets use the VPC default route table — local traffic only
- This is the simplest and most secure baseline; add a NAT Gateway later if private instances need outbound internet

### Why `for_each` Instead of `count`

The networking module uses `for_each` with a map of subnet definitions:

```hcl
resource "aws_subnet" "public" {
  for_each          = var.public_subnets        # map keyed by name
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
}
```

| `count` | `for_each` |
|---------|------------|
| Resources indexed by position (0, 1, 2) | Resources keyed by name ("public-1") |
| Removing index 0 forces recreation of 1, 2 | Removing "public-1" doesn't affect "public-2" |
| Fragile for infra that must not be destroyed | Safe for long-lived networking resources |

---

## Database Tier

### RDS Configuration

```
┌────────────────────────────────────────────┐
│              RDS PostgreSQL 16.4           │
│                                            │
│  Instance:    db.t3.micro                  │
│  Storage:     20 GB gp3 (encrypted)        │
│  Subnets:     private-1, private-2         │
│  Multi-AZ:    false (cost; enable for prod)│
│  Public:      false                        │
│  Final Snap:  skipped (assessment)         │
└────────────────────────────────────────────┘
```

### Security Group Rules

```
┌──────────────────────────────────────────┐
│          rds-sg (northwind-rds-sg)       │
├──────────────────────────────────────────┤
│  INBOUND                                 │
│  ┌────────┬───────┬────────────────────┐ │
│  │ Port   │ Proto │ Source             │ │
│  ├────────┼───────┼────────────────────┤ │
│  │ 5432   │ TCP   │ 192.168.0.0/16    │ │
│  └────────┴───────┴────────────────────┘ │
│                                          │
│  OUTBOUND                                │
│  ┌────────┬───────┬────────────────────┐ │
│  │ All    │ All   │ 0.0.0.0/0         │ │
│  └────────┴───────┴────────────────────┘ │
└──────────────────────────────────────────┘
```

**Why VPC CIDR and not a security group reference?**

Using the VPC CIDR (`192.168.0.0/16`) as the ingress source means any resource inside the VPC — current or future — can reach the database without modifying the SG. For a tighter lockdown in production, replace this with a reference to the instance security group:

```hcl
# Tighter alternative for production:
ingress {
  from_port       = 5432
  to_port         = 5432
  protocol        = "tcp"
  security_groups = [var.instance_sg_id]   # Only web servers
}
```

### Production Hardening Checklist

| Setting | Assessment | Production |
|---------|-----------|------------|
| `multi_az` | `false` | `true` — automatic failover |
| `skip_final_snapshot` | `true` | `false` + `final_snapshot_identifier` |
| `storage_encrypted` | `true` | `true` + customer-managed KMS key |
| `deletion_protection` | omitted | `true` |
| `backup_retention_period` | default (1) | `7–35` days |
| `performance_insights_enabled` | omitted | `true` |
| Password management | `var.db_password` | AWS Secrets Manager + `manage_master_user_password = true` |

---

## Application Tier

### Traffic Flow

```
    Client HTTP Request
           │
           ▼
    ┌──────────────┐
    │     ALB      │  Port 80, HTTP
    │  (public SG) │  Listener → Forward to Target Group
    └──────┬───────┘
           │
           │  Health check: GET / → expect 200
           │  Interval: 30s, Timeout: 5s
           │  Healthy: 2, Unhealthy: 3
           │
    ┌──────▼───────────────────────────────┐
    │          Target Group                │
    │    ┌───────────┐  ┌───────────┐      │
    │    │ Instance  │  │ Instance  │ ...  │
    │    │  (AZ-a)   │  │  (AZ-b)   │      │
    │    │  nginx    │  │  nginx    │      │
    │    └───────────┘  └───────────┘      │
    │         Auto Scaling Group           │
    │         min=1  desired=1  max=3      │
    └──────────────────────────────────────┘
```

### Security Group Chain

A layered security group design ensures each tier only accepts traffic from the tier above:

```
    Internet
       │
       ▼
  ┌─────────────────────┐
  │    ALB SG            │    Ingress: 0.0.0.0/0 :80
  │    (northwind-alb-sg)│    Egress:  all
  └──────────┬──────────┘
             │  SG reference
             ▼
  ┌─────────────────────────┐
  │    Instance SG           │    Ingress: ALB SG :80 (SG-to-SG ref)
  │    (northwind-instance-sg)│   Egress:  all
  └──────────┬──────────────┘
             │  VPC CIDR
             ▼
  ┌─────────────────────┐
  │    RDS SG            │    Ingress: 192.168.0.0/16 :5432
  │    (northwind-rds-sg)│    Egress:  all
  └─────────────────────┘
```

**Why SG-to-SG references matter:**
- Instance SG allows port 80 only from `aws_security_group.alb.id`
- Even if someone places a rogue instance in the public subnet, it cannot reach the web servers unless it belongs to the ALB security group
- This is more restrictive than using a CIDR-based rule

### Launch Template & User Data

```bash
#!/bin/bash
dnf install -y nginx          # Amazon Linux 2023 uses dnf, not yum
systemctl enable --now nginx   # Start immediately + survive reboots
```

**Why Amazon Linux 2023?**
- AWS-optimized, fast boot, minimal attack surface
- `dnf` package manager (AL2 used `yum` — a common interview gotcha)
- Latest AMI fetched dynamically via `data.aws_ami` — no hardcoded AMI IDs

### Auto Scaling Group Behavior

```
         Load Increase
              │
              ▼
   ┌───────────────────┐
   │  ASG scales out   │   1 → 2 → 3 instances
   │  (max: 3)         │
   └───────────────────┘
              │
              ▼
   ┌───────────────────┐
   │  ALB distributes  │   Round-robin across healthy targets
   │  across AZs       │
   └───────────────────┘
              │
              ▼
         Load Decrease
              │
              ▼
   ┌───────────────────┐
   │  ASG scales in    │   3 → 2 → 1 instances
   │  (min: 1)         │
   └───────────────────┘
```

The ASG uses `$Latest` launch template version — any update to the template (new AMI, changed user data) is picked up on next scale-out without redeploying the ASG resource.

---

## CI/CD Pipeline

### Pipeline Decision Tree

```
                        Push / PR to main
                              │
                              ▼
                    ┌───────────────────┐
                    │  detect-changes   │
                    │  (git diff)       │
                    └────────┬──────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
        global/** ?    apps/X/** ?    docs only?
              │              │              │
              ▼              ▼              ▼
     Plan ALL apps     Plan app X     Skip pipeline
     (payment-api      only           (exit 0)
      + user-api)
              │              │
              └──────┬───────┘
                     ▼
           ┌───────────────────┐
           │  terraform-plan   │
           │  (matrix job)     │
           │                   │
           │  payment-api ─┐   │
           │  user-api ────┤   │  Parallel execution
           │               │   │
           └───────────────┘   │
                     │         │
                     ▼         ▼
           ┌───────────────────────┐
           │  Job Summary output   │
           │  (plan per target)    │
           └───────────────────────┘
```

### Matrix Strategy Explained

The pipeline uses a **dynamic matrix** — the `detect-changes` job builds a JSON array of targets at runtime, and `terraform-plan` fans out over them:

```yaml
# detect-changes outputs:
#   {"target": ["apps/payment-api"]}                    # single app changed
#   {"target": ["apps/payment-api", "apps/user-api"]}   # global changed
#   {"target": []}                                       # docs only → skip

# terraform-plan uses:
strategy:
  matrix: ${{ fromJson(needs.detect-changes.outputs.matrix) }}
```

| Scenario | Changed Files | Matrix Targets | Jobs Run |
|----------|---------------|----------------|----------|
| App change | `apps/payment-api/main.tf` | `["apps/payment-api"]` | 1 plan |
| Global change | `global/iam/policies.tf` | `["apps/payment-api", "apps/user-api"]` | 2 plans |
| Both apps | `apps/payment-api/...` + `apps/user-api/...` | `["apps/payment-api", "apps/user-api"]` | 2 plans |
| Docs only | `CHANGELOG.md` | `[]` | 0 (skipped) |
| Global + app | `global/s3/...` + `apps/user-api/...` | `["apps/payment-api", "apps/user-api"]` | 2 plans (deduplicated) |

### Why This Solves the Race Condition

The original problem: all Terraform stacks run on every push, causing state file lock contention.

```
  BEFORE (race condition)              AFTER (smart pipeline)
  ─────────────────────               ──────────────────────
  push to payment-api                 push to payment-api
       │                                   │
       ├── plan payment-api ─┐             └── plan payment-api only
       ├── plan user-api ────┤ LOCK                 (no contention)
       └── plan global ──────┘ CONFLICT
```

Each matrix job runs in its own isolated runner with its own `working-directory`, so parallel plans target different state files and never conflict.

---

## Security Best Practices

### Applied in This Architecture

| Practice | Implementation | Why It Matters |
|----------|---------------|----------------|
| **Network isolation** | RDS in private subnets, no public IP | Database is unreachable from the internet |
| **Least-privilege SGs** | Instance SG only accepts from ALB SG | Even public-subnet resources can't bypass the ALB |
| **Encryption at rest** | `storage_encrypted = true` on RDS | Protects data if disk is physically compromised |
| **No hardcoded secrets** | `sensitive = true` on password vars | Terraform won't print values in logs or plan output |
| **DNS hostnames enabled** | `enable_dns_hostnames = true` on VPC | Required for RDS endpoints to resolve correctly |
| **Dynamic AMI lookup** | `data.aws_ami` with filters | Always gets latest patched AMI, no stale images |
| **OIDC for CI/CD** | `id-token: write` + role assumption | No long-lived AWS credentials in GitHub secrets |
| **Separate SG per tier** | ALB SG, Instance SG, RDS SG | Blast radius limited if one tier is compromised |

### Recommended Additions for Production

```
┌─────────────────────────────────────────────────────────────────┐
│                    Production Security Layers                   │
│                                                                 │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌──────────────┐  │
│  │   WAF    │→ │   ALB    │→ │    EC2    │→ │     RDS      │  │
│  │ (shield) │  │  (HTTPS) │  │ (hardened)│  │ (encrypted)  │  │
│  └──────────┘  └──────────┘  └───────────┘  └──────────────┘  │
│                                                                 │
│  + VPC Flow Logs          + Secrets Manager for DB password     │
│  + GuardDuty              + ACM certificate for HTTPS           │
│  + Config Rules           + IMDSv2 enforced on instances        │
│  + CloudTrail             + KMS customer-managed keys           │
└─────────────────────────────────────────────────────────────────┘
```

---

## Terraform Best Practices

### Module Structure (DRY)

```
root
 │
 │  Defines WHAT to build (variable values, module wiring)
 │
 ├── modules/networking     ─── Defines HOW to build the network
 ├── modules/database       ─── Defines HOW to build the database
 └── modules/compute        ─── Defines HOW to build the app tier
```

Each module is:
- **Self-contained** — has its own `variables.tf`, `main.tf`, `outputs.tf`
- **Reusable** — can be called multiple times with different inputs (e.g., staging vs production)
- **Testable** — can be validated independently with `terraform validate`

### DRY Principles Applied

| Technique | Example | Benefit |
|-----------|---------|---------|
| **Modules** | `module "networking"` encapsulates VPC+subnets+routes | Change once, propagate everywhere |
| **`for_each`** | Single `aws_subnet` resource creates all public subnets | No copy-paste per AZ |
| **Community modules** | `terraform-aws-modules/alb/aws` | Don't reinvent ALB wiring |
| **Locals** | `local.azs` computed from data source | AZ names not hardcoded |
| **Variables with defaults** | `var.asg_min = 1` | Override per environment, sensible baseline |

### State Management (Production Recommendation)

```hcl
# Add to providers.tf for real deployments:
terraform {
  backend "s3" {
    bucket         = "northwind-terraform-state"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

| Concern | Solution |
|---------|----------|
| State locking | DynamoDB table prevents concurrent applies |
| State encryption | S3 SSE + `encrypt = true` |
| State isolation | Separate keys per environment (`prod/`, `staging/`) |
| State backup | S3 versioning enabled |

---

## Operational Runbook

### Common Commands

```bash
# Initialize and validate
terraform init
terraform validate
terraform fmt -check

# Plan with variable file
terraform plan -var-file="prod.tfvars" -out=plan.tfplan

# Apply a saved plan (no surprises)
terraform apply plan.tfplan

# Inspect current state
terraform state list
terraform output alb_dns_name

# Target a single module for faster iteration
terraform plan -target=module.compute
```

### Scaling the ASG Manually

```bash
# Scale to 3 instances during expected traffic spike
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name northwind-asg \
  --desired-capacity 3

# Scale back down
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name northwind-asg \
  --desired-capacity 1
```

### Verifying the Deployment

```bash
# 1. Get ALB DNS
ALB=$(terraform output -raw alb_dns_name)

# 2. Curl the endpoint (expect nginx welcome page)
curl -s -o /dev/null -w "%{http_code}" http://$ALB
# Expected: 200

# 3. Check target health
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw target_group_arn)
```

### Tear Down

```bash
# Destroy all resources (with confirmation prompt)
terraform destroy -var-file="prod.tfvars"
```

---

## File Reference

| File | Purpose |
|------|---------|
| `main.tf` | Root module — wires networking → database → compute |
| `variables.tf` | Input variables with sensible defaults |
| `outputs.tf` | ALB DNS name, RDS endpoint, VPC ID |
| `providers.tf` | AWS provider + version constraints |
| `modules/networking/` | VPC, 4 subnets, IGW, route tables |
| `modules/database/` | RDS PostgreSQL, subnet group, security group |
| `modules/compute/` | ALB (community module), launch template, ASG |
| `.github/workflows/pipeline.yml` | Smart conditional CI/CD pipeline |
