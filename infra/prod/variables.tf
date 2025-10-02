variable "project_name" {
  type = string
}
variable "region" {
  type    = string
  default = "ap-northeast-1"
}
variable "key_name" {
  type = string
}
variable "allowed_ssh_cidr" {
  type = string
}
variable "instance_type" {
  type    = string
  default = "t4g.medium"
}
variable "data_volume_size_gb" {
  type    = number
  default = 100
}
variable "domain_name" {
  type    = string
  default = ""
}
variable "hosted_zone_name" {
  type    = string
  default = ""
}
variable "s3_lifecycle_ia_days" {
  type    = number
  default = 90
}
variable "s3_lifecycle_glacier_days" {
  type    = number
  default = 365
}
