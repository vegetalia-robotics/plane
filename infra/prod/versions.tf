terraform {
  required_version = ">= 1.6.0"
  backend "s3" {}  # -backend-config=backend.hcl で設定注入
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    template = {
      source  = "hashicorp/template"
      version = "~> 2.2"
    }
  }
}
