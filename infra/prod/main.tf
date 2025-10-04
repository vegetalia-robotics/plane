locals {
  name = lower(var.project_name)
  tags = { Project = title(var.project_name), Stack = "plane" }
}

data "aws_availability_zones" "available" {}
data "aws_caller_identity" "current" {}

# VPC
resource "aws_vpc" "this" {
  cidr_block           = "10.11.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = merge(local.tags, { Name = "${local.name}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${local.name}-igw" })
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.11.0.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags = merge(local.tags, { Name = "${local.name}-public-a", Tier = "public" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${local.name}-public-rt" })
}
resource "aws_route" "public_inet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}
resource "aws_route_table_association" "public_a" {
  route_table_id = aws_route_table.public.id
  subnet_id      = aws_subnet.public_a.id
}

# SG
resource "aws_security_group" "app" {
  name   = "${local.name}-sg"
  vpc_id = aws_vpc.this.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "Postgres"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    self        = true
  }
  ingress {
    description = "Redis"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    self        = true
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.tags, { Name = "${local.name}-sg" })
}

# IAM for EC2
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${local.name}-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Allow instance to pull images from ECR
resource "aws_iam_role_policy_attachment" "ecr_readonly" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name}-ec2"
  role = aws_iam_role.ec2.name
}

# S3 uploads
resource "aws_s3_bucket" "uploads" {
  bucket = "${local.name}-${data.aws_caller_identity.current.account_id}-uploads"
  tags   = local.tags
}
resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  versioning_configuration {
    status = "Enabled"
  }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    id     = "transition"
    status = "Enabled"
    filter {
      prefix = ""
    }
    transition {
      days          = var.s3_lifecycle_ia_days
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = var.s3_lifecycle_glacier_days
      storage_class = "GLACIER"
    }
  }
}

# Random secrets
resource "random_password" "postgres" {
  length  = 24
  special = false
}
resource "random_password" "redis" {
  length  = 24
  special = false
}
resource "random_password" "secret" {
  length  = 48
  special = false
}

# AMI (Ubuntu ARM64)
data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"]
  }
}

# EC2
resource "aws_instance" "app" {
  ami                         = data.aws_ami.ubuntu_arm64.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public_a.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/templates/user_data_template.sh", {
    plane_secret_key = random_password.secret.result
    database_password= random_password.postgres.result
    redis_url        = format("redis://:%s@redis:6379/0", random_password.redis.result)
    s3_endpoint      = ""
    s3_bucket        = aws_s3_bucket.uploads.bucket
    s3_access_key    = ""
    s3_secret_key    = ""
    aws_region       = var.region
    ecr_backend_uri  = aws_ecr_repository.backend.repository_url
    ecr_frontend_uri = aws_ecr_repository.frontend.repository_url
  })

  tags = merge(local.tags, { Name = "${local.name}-ec2" })
}

# EBS gp3 (data)
resource "aws_ebs_volume" "data" {
  availability_zone = aws_instance.app.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  tags = merge(local.tags, { Name = "${local.name}-data", Backup = "Yes" })
}
resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.app.id
}

# EIP (for stable DNS A record)
resource "aws_eip" "this" {
  domain   = "vpc"
  instance = aws_instance.app.id
  tags     = merge(local.tags, { Name = "${local.name}-eip" })
}

# Route53 (optional)
data "aws_route53_zone" "this" {
  count        = length(var.hosted_zone_name) > 0 ? 1 : 0
  name         = var.hosted_zone_name
  private_zone = false
}
resource "aws_route53_record" "a" {
  count   = length(var.hosted_zone_name) > 0 && length(var.domain_name) > 0 ? 1 : 0
  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = 60
  records = [aws_eip.this.public_ip]
}

# ECR repositories (backend & frontend)
resource "aws_ecr_repository" "backend" {
  name                 = "${local.name}-backend"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = local.tags
}
resource "aws_ecr_repository" "frontend" {
  name                 = "${local.name}-frontend"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = local.tags
}

# AWS Backup (EBS selection by tag)
resource "aws_backup_vault" "main" {
  name = "${local.name}-vault"
  tags = local.tags
}
resource "aws_backup_plan" "main" {
  name = "${local.name}-plan"
  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 18 * * ? *)"
    lifecycle { delete_after = 14 }
  }
  rule {
    rule_name         = "weekly"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 19 ? * SUN *)"
    lifecycle { delete_after = 60 }
  }
  rule {
    rule_name         = "monthly"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 20 1 * ? *)"
    lifecycle { delete_after = 365 }
  }
  tags = local.tags
}
resource "aws_iam_role" "backup" {
  name               = "${local.name}-backup"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "backup.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}
resource "aws_iam_role_policy_attachment" "backup_attach" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}
resource "aws_backup_selection" "by_tag" {
  iam_role_arn = aws_iam_role.backup.arn
  name         = "${local.name}-select"
  plan_id      = aws_backup_plan.main.id
  selection_tag {
    type  = "STRINGEQUALS"
    key   = "Backup"
    value = "Yes"
  }
}

output "ec2_public_ip" { value = aws_eip.this.public_ip }
output "uploads_bucket" { value = aws_s3_bucket.uploads.bucket }
output "ecr_backend" { value = aws_ecr_repository.backend.repository_url }
output "ecr_frontend" { value = aws_ecr_repository.frontend.repository_url }
