#!/bin/bash
#
# user_data_plane.sh - Setup script for Plane on an EC2 instance
#
# This script is intended to be used as EC2 user‑data.  It installs Docker
# and the docker‑compose CLI plugin, installs the AWS CLI, writes out
# environment configuration files, pulls your Plane images from Amazon ECR,
# starts the containers, and registers a systemd unit so that Plane
# automatically starts on boot.  Variable placeholders (e.g. ${plane_secret_key})
# should be substituted by Terraform or your templating engine before use.

set -euo pipefail

# Create working directory for Plane.  Use sudo to ensure we can write to
# /opt; cloud‑init runs as root so this will succeed.
mkdir -p /opt/plane
cd /opt/plane

# -----------------------------------------------------------------------------
# Write application configuration (.env)
#
# Populate this file with your actual secrets and connection strings.  The
# placeholders here (e.g. ${plane_secret_key}) are meant to be replaced by
# Terraform variables via template interpolation.  Do not leave the values
# literally wrapped in braces when running in production.
cat > .env <<'ENVEOF'
PLANE_SECRET_KEY=${plane_secret_key}
# Password for the Postgres user.  Ensure this matches the value used
# in the postgres service definition below.  It is provided by
# Terraform as `database_password`.
POSTGRES_PASSWORD=${database_password}
# Construct the full connection URL with the same password.  Compose
# does not perform nested variable interpolation inside .env files, so
# we embed the password directly.
DATABASE_URL=postgresql://plane:${database_password}@postgres:5432/plane
REDIS_URL=${redis_url}
S3_ENDPOINT=${s3_endpoint}
S3_BUCKET=${s3_bucket}
S3_ACCESS_KEY=${s3_access_key}
S3_SECRET_KEY=${s3_secret_key}
AWS_REGION=${aws_region}
ENVEOF

# -----------------------------------------------------------------------------
# Write ECR image configuration (.env.ecr)
#
# These URIs should point at the private ECR repositories containing your
# Plane backend and frontend images.  Substitute these placeholders with
# Terraform variables.
cat > .env.ecr <<'ECREOF'
ECR_BACKEND=${ecr_backend_uri}
ECR_FRONTEND=${ecr_frontend_uri}
ECREOF

# -----------------------------------------------------------------------------
# Write default Docker Compose files
#
# If your repository does not provide docker-compose.yml and
# docker-compose.prod.yml, the lines below will create minimal versions so
# Plane can start.  You can replace these definitions with your own custom
# Compose files via Terraform or manual provisioning.  The first file
# defines infrastructure services (PostgreSQL and Redis); the second
# defines the Plane backend and frontend, using the ECR image URIs from
# .env.ecr.
cat > docker-compose.yml <<'COMPOSEEOF'
version: '3.8'
services:
  postgres:
    image: postgres:16
    restart: always
    environment:
      POSTGRES_USER: plane
      POSTGRES_PASSWORD: $${database_password}
      POSTGRES_DB: plane
    volumes:
      - postgres_data:/var/lib/postgresql/data

  redis:
    image: redis:7
    restart: always
    volumes:
      - redis_data:/data

volumes:
  postgres_data:
  redis_data:
COMPOSEEOF

cat > docker-compose.prod.yml <<'COMPOSEPROD'
version: '3.8'
services:
  backend:
    # This image URI is substituted by Terraform via the ecr_backend_uri variable
    image: ${ecr_backend_uri}
    restart: always
    env_file:
      - .env
    depends_on:
      - postgres
      - redis

  frontend:
    # This image URI is substituted by Terraform via the ecr_frontend_uri variable
    image: ${ecr_frontend_uri}
    restart: always
    depends_on:
      - backend
    ports:
      - "80:3000"
    environment:
      # Expose the API URL for the frontend to talk to the backend. The
      # hostname "backend" resolves to the backend service within the
      # compose network. Do not set this to localhost, as the frontend
      # container does not run the API itself.
      NEXT_PUBLIC_API_URL: http://backend:8000
COMPOSEPROD

# -----------------------------------------------------------------------------
# Install system dependencies
#
# Update package metadata and install Docker, unzip, and curl.  We also
# install awscli v2 later if it is not already present.  apt-get update can
# occasionally fail on first boot due to network not being ready; retry up to
# five times before giving up.
for attempt in {1..5}; do
    if apt-get update; then
        break
    fi
    sleep 15
done
apt-get install -y docker.io unzip curl

# Enable and start Docker
systemctl enable --now docker

# -----------------------------------------------------------------------------
# Install AWS CLI v2
#
# The AWS CLI is required for logging in to ECR.  If the `aws` command is not
# available, download and install the CLI.  Cleanup temporary files
# afterwards.
if ! command -v aws >/dev/null 2>&1; then
    tmpdir=$(mktemp -d)
    curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "$tmpdir/awscliv2.zip"
    unzip -q "$tmpdir/awscliv2.zip" -d "$tmpdir"
    "$tmpdir/aws/install"
    rm -rf "$tmpdir"
fi

# -----------------------------------------------------------------------------
# Install docker compose (v2) CLI plugin
#
# The docker.io package on Ubuntu 22.04 does not include the compose v2
# plugin by default.  If `docker compose version` fails, download the
# appropriate binary and place it in the CLI plugin directory.  This makes
# `docker compose` available as a subcommand of `docker`.
if ! docker compose version >/dev/null 2>&1; then
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -sSL "https://github.com/docker/compose/releases/download/v2.24.2/docker-compose-linux-aarch64" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi

# -----------------------------------------------------------------------------
# Authenticate to Amazon ECR
#
# Retrieve the AWS account ID using the AWS CLI and then perform an ECR
# login.  The instance must have an IAM role attached that allows
# "ecr:GetAuthorizationToken" and that permits reading from your ECR
# repositories.  Without these permissions the login will fail.  The region
# variable is read from AWS_REGION (written into .env above).
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="${aws_region}"
aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

# -----------------------------------------------------------------------------
# Pull and start Plane services using Docker Compose
#
# Compose files `docker-compose.yml` and `docker-compose.prod.yml` should be
# present in /opt/plane (for example via Terraform write_files).  Pull the
# images first (ignore errors if not present yet), then bring up the stack in
# the background.  `|| true` ensures that the script continues even if the
# pull fails (e.g. because the image hasn't been pushed yet).
docker compose -f docker-compose.yml -f docker-compose.prod.yml pull || true
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --remove-orphans || true
# Run database migrations
# After services are up, apply pending Django migrations.
docker compose -f docker-compose.yml -f docker-compose.prod.yml run --rm backend python manage.py migrate --noinput || true

# -----------------------------------------------------------------------------
# Register a systemd unit so Plane starts on boot
#
# The unit invokes `docker compose up` when started and `docker compose down`
# when stopped.  We load environment variables from .env.ecr to supply the
# image URIs.  The service is marked as Type=oneshot because the compose
# command stays in the foreground only briefly (then spawns containers and
# exits).
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

# Reload systemd to pick up the new unit and enable it
systemctl daemon-reload
systemctl enable plane-compose.service
systemctl restart plane-compose.service