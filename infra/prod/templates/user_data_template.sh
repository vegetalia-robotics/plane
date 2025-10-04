#!/bin/bash
set -euo pipefail

# Create working directory
mkdir -p /opt/plane
cd /opt/plane

# Write .env file with application configuration
# Replace the placeholders via Terraform variables or hard-coded values as needed
cat > .env <<'ENVEOF'
PLANE_SECRET_KEY=${plane_secret_key}
DATABASE_URL=${database_url}
REDIS_URL=${redis_url}
S3_ENDPOINT=${s3_endpoint}
S3_BUCKET=${s3_bucket}
S3_ACCESS_KEY=${s3_access_key}
S3_SECRET_KEY=${s3_secret_key}
AWS_REGION=${aws_region}
ENVEOF

# Write environment file for ECR image URIs
cat > .env.ecr <<'ECREOF'
ECR_BACKEND=${ecr_backend_uri}
ECR_FRONTEND=${ecr_frontend_uri}
ECREOF

# Install dependencies: curl, unzip, docker, docker-compose, awscli
apt-get update
apt-get install -y docker.io unzip curl

# Enable and start Docker service
systemctl enable --now docker

# Install AWS CLI v2 if not already installed
if ! command -v aws >/dev/null 2>&1; then
    curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "/tmp/awscliv2.zip"
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install
    rm -rf /tmp/aws /tmp/awscliv2.zip
fi

# Install docker-compose v2 if not installed
if ! docker compose version >/dev/null 2>&1; then
    # Compose v2 plugin might already come with newer docker.io packages; fallback to manual install
    curl -SL "https://github.com/docker/compose/releases/download/v2.24.2/docker-compose-linux-aarch64" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

# Login to Amazon ECR using AWS CLI
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="${aws_region}"
aws ecr get-login-password --region "$REGION" | \
    docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

# Pull and start Docker Compose services
# Ensure docker-compose.yml and docker-compose.prod.yml exist in /opt/plane
/usr/bin/docker compose -f docker-compose.yml -f docker-compose.prod.yml pull || true
/usr/bin/docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --remove-orphans || true

# Register systemd unit for automatic restart on boot
cat > /etc/systemd/system/plane-compose.service <<'SERVICEEOF'
[Unit]
Description=Plane Compose Service
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/plane
EnvironmentFile=/opt/plane/.env.ecr
ExecStart=/usr/bin/docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --remove-orphans
ExecStop=/usr/bin/docker compose -f docker-compose.yml -f docker-compose.prod.yml down

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable plane-compose.service
systemctl restart plane-compose.service

