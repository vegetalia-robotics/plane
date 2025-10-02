provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = title(var.project_name)
      Stack   = "plane"
    }
  }
}
