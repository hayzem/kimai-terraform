provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "vpc" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_subnet" "vpc" {
  for_each = toset(data.aws_subnets.vpc.ids)
  id       = each.value
}

locals {
  availability_zones = sort(distinct([for s in data.aws_subnet.vpc : s.availability_zone]))
  alb_subnet_ids = length(local.availability_zones) >= 2 ? [
    for az in slice(local.availability_zones, 0, 2) :
    [for s in values(data.aws_subnet.vpc) : s.id if s.availability_zone == az][0]
  ] : slice(sort(data.aws_subnets.vpc.ids), 0, min(2, length(data.aws_subnets.vpc.ids)))

  instance_subnet_id = coalesce(var.kimai_instance_subnet_id, local.alb_subnet_ids[0])
  kimai_url          = "https://${var.kimai_hostname}/"
  # ALB health checks send Host: <target private IP> (TF AWS provider has no health_check.host yet).
  vpc_prefix_parts   = split(".", split("/", data.aws_vpc.default.cidr_block)[0])
  vpc_host_regex     = "${local.vpc_prefix_parts[0]}\\.${local.vpc_prefix_parts[1]}\\.[0-9]{1,3}\\.[0-9]{1,3}"
  trusted_hosts      = "${var.kimai_hostname}|localhost|127.0.0.1|${local.vpc_host_regex}"
  trusted_proxies    = coalesce(var.trusted_proxies, data.aws_vpc.default.cidr_block)

  env_rendered = templatefile("${path.module}/templates/env.tmpl", {
    APP_SECRET              = var.app_secret
    DATABASE_NAME           = var.database_name
    DATABASE_USER           = var.database_user
    DATABASE_PASSWORD       = var.database_password
    DATABASE_ROOT_PASSWORD  = var.database_root_password
    TRUSTED_HOSTS           = local.trusted_hosts
    TRUSTED_PROXIES         = local.trusted_proxies
    ADMIN_EMAIL             = var.admin_email
    ADMIN_PASSWORD          = var.admin_password
    MAILER_FROM             = var.mailer_from
    MAILER_URL              = var.mailer_url
    TIMEZONE                = var.timezone
  })

  compose_rendered = templatefile("${path.module}/templates/docker-compose.yml.tmpl", {
    data_mount_path = var.kimai_data_mount_path
  })

  # Do not reference aws_ebs_volume.kimai_data.id here — avoids Terraform replace/destroy cycles.
  user_data_rendered = templatefile("${path.module}/templates/user_data.sh.tmpl", {
    env_file          = replace(local.env_rendered, "$", "\\$")
    compose_file      = replace(local.compose_rendered, "$", "\\$")
    data_mount_path   = var.kimai_data_mount_path
  })
}

data "aws_subnet" "kimai_instance" {
  id = local.instance_subnet_id
}

resource "aws_ebs_volume" "kimai_data" {
  availability_zone = data.aws_subnet.kimai_instance.availability_zone
  size              = var.kimai_data_volume_size_gb
  type              = "gp3"

  tags = {
    Name = "kimai-data"
  }
}

resource "aws_iam_role" "kimai_ec2" {
  name = "kimai-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "kimai_ssm" {
  role       = aws_iam_role.kimai_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "kimai" {
  name = "kimai-ec2-ssm-profile"
  role = aws_iam_role.kimai_ec2.name
}

resource "aws_security_group" "alb_sg" {
  name   = "kimai-alb-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "kimai_sg" {
  name   = "kimai-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port       = 8001
    to_port         = 8001
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_instance" "kimai" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = local.instance_subnet_id
  vpc_security_group_ids      = [aws_security_group.kimai_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.kimai.name
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 15
    delete_on_termination = true
  }

  user_data = local.user_data_rendered

  tags = {
    Name = "kimai-server"
  }
}

resource "aws_volume_attachment" "kimai_data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.kimai_data.id
  instance_id = aws_instance.kimai.id
}

resource "aws_lb" "kimai" {
  name               = "kimai-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = local.alb_subnet_ids
}

resource "aws_lb_target_group" "kimai" {
  name     = "kimai-tg"
  port     = 8001
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    enabled             = true
    path                = "/"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200-399"
  }
}

resource "aws_lb_target_group_attachment" "kimai" {
  target_group_arn = aws_lb_target_group.kimai.arn
  target_id        = aws_instance.kimai.id
  port             = 8001
}

resource "aws_lb_listener" "kimai_https" {
  load_balancer_arn = aws_lb.kimai.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kimai.arn
  }
}

resource "aws_lb_listener" "kimai_http_redirect" {
  load_balancer_arn = aws_lb.kimai.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
