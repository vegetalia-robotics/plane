#!/bin/bash
set -euo pipefail

# Create working directory
mkdir -p /opt/plane
cd /opt/plane

# Write .env file with application configuration.
# Replace the placeholders (e.g., ${database_url}) via Terraform template interpolation.
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

# Install Docker if not already installed
if ! command -v docker >/dev/null 2>&1; then
    apt-get update
    apt-get install -y docker.io
    systemctl enable --now docker
fi

# Install docker compose v2 if not installed
docker_compose_path=$(command -v docker-compose || echo "")
if [ -z "$docker_compose_path" ]; then
    curl -SL https://github.com/docker/compose/releases/download/v2.24.2/docker-compose-linux-aarch64 \
        -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

# Login to Amazon ECR
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="${aws_region}"
aws ecr get-login-password --region "$REGION" |
    docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

# Pull and start Docker Compose services.
# Ensure docker-compose.yml and docker-compose.prod.yml exist in /opt/plane.
/usr/bin/docker compose -f docker-compose.yml -f docker-compose.prod.yml pull
/usr/bin/docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --remove-orphans

# Register systemd unit for automatic restart on boot.
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
systemctl start plane-compose.service

