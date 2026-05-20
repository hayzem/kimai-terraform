variable "aws_region" {
  type        = string
  default     = "us-east-2"
  description = "AWS region for all resources (must match ACM certificate region)."
}

variable "aws_profile" {
  type        = string
  default     = null
  nullable    = true
  description = "AWS shared credentials profile for Terraform. Null uses the default credential chain (e.g. AWS_PROFILE environment variable)."
}

variable "instance_type" {
  type        = string
  default     = "t3.small"
  description = "EC2 instance type for Kimai and MySQL containers."
}

variable "kimai_hostname" {
  type        = string
  description = "Full public hostname clients use (e.g. kimai.example.com). Must match ACM certificate SAN/CN. Primary host in TRUSTED_HOSTS (also includes localhost|127.0.0.1) and kimai_url output."

  validation {
    condition     = can(regex("^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$", var.kimai_hostname)) && !can(regex("^https?://", var.kimai_hostname))
    error_message = "kimai_hostname must be a FQDN without protocol (e.g. kimai.example.com)."
  }
}

variable "acm_certificate_arn" {
  type        = string
  description = "ACM certificate ARN in the same region as aws_region. Must cover kimai_hostname."
}

variable "app_secret" {
  type        = string
  sensitive   = true
  description = "Symfony APP_SECRET for Kimai (use a long random string)."
}

variable "database_name" {
  type        = string
  default     = "kimai"
  description = "MySQL database name for Kimai."
}

variable "database_user" {
  type        = string
  default     = "kimai"
  description = "MySQL application user for Kimai."
}

variable "database_password" {
  type        = string
  sensitive   = true
  description = "MySQL password for the Kimai application user."
}

variable "database_root_password" {
  type        = string
  sensitive   = true
  description = "MySQL root password for the sqldb container."
}

variable "admin_email" {
  type        = string
  description = "Email for the initial Kimai admin user (ADMINMAIL)."
}

variable "admin_password" {
  type        = string
  sensitive   = true
  description = "Password for the initial Kimai admin user (ADMINPASS)."
}

variable "timezone" {
  type        = string
  default     = "America/New_York"
  description = "Timezone for the Kimai container (TIMEZONE)."
}

variable "mailer_from" {
  type        = string
  default     = "kimai@example.com"
  description = "MAILER_FROM address for outbound email."
}

variable "mailer_url" {
  type        = string
  default     = "null://null"
  description = "MAILER_URL per Kimai/Symfony mailer docs. Use null://null to disable email."
}

variable "trusted_proxies" {
  type        = string
  default     = null
  nullable    = true
  description = "TRUSTED_PROXIES for Kimai behind ALB (IP/CIDR only). Defaults to default VPC CIDR when null."
}

variable "kimai_data_volume_size_gb" {
  type        = number
  default     = 30
  description = "Size in GiB for the persistent EBS data volume."
}

variable "kimai_data_mount_path" {
  type        = string
  default     = "/data"
  description = "Mount path for the persistent EBS data volume on the instance."
}

variable "kimai_instance_subnet_id" {
  type        = string
  default     = null
  nullable    = true
  description = "Subnet ID for the Kimai EC2 instance. Must be in the same AZ as the EBS volume. Defaults to the first ALB subnet."
}
