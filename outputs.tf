output "kimai_url" {
  value       = local.kimai_url
  description = "Public HTTPS URL Kimai is configured to use."
}

output "kimai_hostname" {
  value       = var.kimai_hostname
  description = "Hostname configured for Kimai and ACM (TRUSTED_HOSTS)."
}

output "alb_dns_name" {
  value       = aws_lb.kimai.dns_name
  description = "DNS name of the Application Load Balancer — point kimai_hostname here (alias A or CNAME)."
}

output "dns_setup_hint" {
  value       = "Create an alias A record (recommended) or CNAME from ${var.kimai_hostname} to ${aws_lb.kimai.dns_name} (ALB zone ID: ${aws_lb.kimai.zone_id})."
  description = "Manual DNS step when Route 53 is not managed by this module."
}

output "kimai_data_volume_id" {
  value       = aws_ebs_volume.kimai_data.id
  description = "Persistent EBS volume ID for Kimai and MySQL data."
}

output "kimai_data_mount_path" {
  value       = var.kimai_data_mount_path
  description = "Mount path used for persistent data on the instance."
}

output "kimai_instance_id" {
  value       = aws_instance.kimai.id
  description = "EC2 instance ID (use with SSM Session Manager, not SSH)."
}
