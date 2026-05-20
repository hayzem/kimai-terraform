# Kimai on AWS (Terraform)

Terraform deploys a single EC2 instance running [Kimai](https://www.kimai.org/) (`kimai/kimai2:stable`) and **MySQL 8.3** via Docker Compose, behind an **Application Load Balancer** with **HTTPS** (ACM certificate). Persistent data lives on a separate **EBS** volume (MySQL datadir, Kimai uploads/plugins, Docker data-root). **Route 53 is not managed** — you point your full hostname at the ALB in your DNS provider.

Inspired by [hayzem/n8n-terraform](https://github.com/hayzem/n8n-terraform).

## Architecture

```mermaid
flowchart LR
  Users[Users] --> ALB[ALB_HTTPS_443]
  ALB -->|HTTP_8001| EC2[EC2_Ubuntu]
  subgraph ec2 [Docker_Compose]
    Kimai[kimai_kimai2_stable]
    MySQL[mysql_8_3]
    Kimai -->|sqldb_3306| MySQL
  end
  EC2 --> EBS[EBS_gp3_data]
```

- **ALB**: HTTPS on 443, HTTP redirects to HTTPS.
- **EC2**: Ubuntu 22.04, Docker Compose, no SSH key (use **SSM Session Manager**).
- **MySQL**: Container on the same host; not exposed to the internet.
- **Kimai**: Port 8001 only from the ALB security group.

## Disclaimer

**NO WARRANTY.** This repository is provided **as-is** without any warranty. The authors are **not affiliated with the Kimai project**. You are solely responsible for security, compliance, backups, and operations.

The **Kimai application** (when deployed) is licensed under **AGPL-3.0**. Running Kimai may impose obligations on you if you modify or network-serve the software. See [Kimai licensing](https://www.kimai.org/) and your legal counsel.

Terraform configuration in this repo is licensed under **MIT** (see [LICENSE](LICENSE)).

## Prerequisites

- Terraform ≥ 1.0
- AWS CLI credentials with permission to manage EC2, EBS, ELB, VPC, and IAM (instance profile for SSM)
- **ACM certificate** in the **same region** as `aws_region` (default `us-east-2`), covering `kimai_hostname` (e.g. `kimai.example.com`)
- DNS at your provider (alias A or CNAME to the ALB after apply)
- IAM permission to start SSM sessions (`ssm:StartSession`) for troubleshooting

## Quick start

1. Copy and edit variables (do **not** commit secrets):

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Initialize and apply:

   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

3. Note outputs `alb_dns_name` and `dns_setup_hint`. Create DNS for `kimai_hostname` → ALB.

4. Open `kimai_url` (output). Sign in with username **`admin`** and `admin_password` from `terraform.tfvars` (`admin_email` is only the account email, not the login name).

## Configuration (`terraform.tfvars`)

### Required

| Variable | Purpose |
|----------|---------|
| `kimai_hostname` | Full public hostname (e.g. `kimai.example.com`) |
| `acm_certificate_arn` | ACM cert ARN for ALB HTTPS |
| `app_secret` | Kimai `APP_SECRET` |
| `database_password` | MySQL user password |
| `database_root_password` | MySQL root password |
| `admin_email` | Initial admin email (`ADMINMAIL`) |
| `admin_password` | Initial admin password (`ADMINPASS`) |

### Optional (defaults)

| Variable | Default | Notes |
|----------|---------|--------|
| `aws_region` | `us-east-2` | Must match ACM region |
| `aws_profile` | `null` | AWS credentials profile for Terraform; or set `AWS_PROFILE` |
| `instance_type` | `t3.small` | Kimai + MySQL on one host |
| `database_name` | `kimai` | |
| `database_user` | `kimai` | |
| `timezone` | `America/New_York` | Kimai `TIMEZONE` |
| `mailer_from` | `kimai@example.com` | |
| `mailer_url` | `null://null` | Disable email; see [email docs](https://www.kimai.org/documentation/emails.html#mailer_url) |
| `trusted_proxies` | VPC CIDR | IP/CIDR for ALB trust (not hostnames) |
| `kimai_data_volume_size_gb` | `30` | EBS size (GiB) |
| `kimai_data_mount_path` | `/data` | Mount path on instance |
| `kimai_instance_subnet_id` | first ALB subnet | **Same AZ as EBS** |

## AWS credentials profile

Set the profile Terraform uses to call AWS API:

```hcl
aws_profile = "my-profile"
```

in `terraform.tfvars`, or export `AWS_PROFILE=my-profile` and leave `aws_profile` unset (default credential chain).

## TRUSTED_HOSTS behind the ALB

Kimai 2.42+ enforces Symfony `TRUSTED_HOSTS` as a **regex** with **pipe-separated** hosts ([kimai#5693](https://github.com/kimai/kimai/issues/5693)). This module sets:

```text
<kimai_hostname>|localhost|127.0.0.1|<vpc-prefix>.\d+.\d+
```

Example for default VPC `172.31.0.0/16`: `kimai.example.com|localhost|127.0.0.1|172\.31\.[0-9]{1,3}\.[0-9]{1,3}`

`TRUSTED_HOSTS` also includes a regex for the default VPC subnet (e.g. `172.31.x.x`) because ALB health checks send `Host: <target private IP>`. The Terraform AWS provider does not yet expose a custom health-check `Host` header on `aws_lb_target_group`; when it does, we can narrow this list to the public hostname only.

## DNS (external)

This module does **not** create Route 53 records. After apply:

```text
kimai.example.com  →  alias A (or CNAME)  →  <alb_dns_name output>
```

Use the ALB hosted zone ID from your AWS console or `dns_setup_hint` output when creating an alias record in Route 53 or another DNS provider.

## Email

Configure `mailer_url` and `mailer_from` per [Kimai email documentation](https://www.kimai.org/documentation/emails.html#mailer_url). Examples:

- Disabled: `null://null`
- SMTP: `smtp://user:password@smtp.example.com:587?encryption=tls`
- Gmail: `smtps://user:password@gmail.com:465`

**URL-encode** special characters in SMTP passwords (`@`, `#`, `:`, etc.):

```bash
php -r "echo urlencode('your-password');"
```

Test after deploy (via SSM):

```bash
aws ssm start-session --target <kimai_instance_id>
sudo su -
cd /data/kimai
docker compose exec kimai /opt/kimai/bin/console kimai:mail:test recipient@example.com
```

## Operations (SSM, no SSH)

No SSH key is provisioned. Connect with Session Manager:

```bash
aws ssm start-session --target $(terraform output -raw kimai_instance_id)
```

Then inspect containers:

```bash
cd /data/kimai   # or your kimai_data_mount_path/kimai
sudo docker compose ps
sudo docker compose logs -f kimai
```

Restrict `ssm:StartSession` in IAM to trusted principals.

## What Terraform creates

- **EC2** — Ubuntu 22.04; user data mounts EBS, installs Docker, writes `docker-compose.yml` + `.env`, runs `docker compose up -d`
- **EBS** — `gp3` volume for MySQL, Kimai data/plugins, Docker root
- **Security groups** — ALB: 80/443 from internet; instance: 8001 from ALB only
- **ALB** — HTTPS to target group on port 8001
- **IAM** — Instance profile for SSM (`AmazonSSMManagedInstanceCore`)

## Outputs

| Output | Description |
|--------|-------------|
| `kimai_url` | Configured HTTPS base URL |
| `kimai_hostname` | Hostname for ACM/DNS |
| `alb_dns_name` | ALB DNS name for your DNS record |
| `dns_setup_hint` | Short DNS instruction string |
| `kimai_data_volume_id` | Persistent EBS volume ID |
| `kimai_data_mount_path` | Mount path on the instance |
| `kimai_instance_id` | EC2 ID for SSM |

## Upgrading an existing deployment

Terraform changes to `.env` / `docker-compose.yml` in user data **do not** re-run on an already-created EC2 instance. After pulling these fixes:

1. **Terraform** (updates ALB health check in place):

   ```bash
   terraform apply
   ```

2. **On the instance via SSM** (updates Kimai env on the EBS volume):

   ```bash
   cd /data/kimai   # or <kimai_data_mount_path>/kimai
   # Ensure .env contains:
   # TRUSTED_HOSTS=<your-hostname>|localhost|127.0.0.1|<vpc-prefix-regex>
   # (copy full line from a fresh terraform apply plan / generated .env on a new instance, or use the pattern in main.tf locals)
   sudo docker compose up -d --force-recreate kimai
   ```

3. Confirm the ALB target is **healthy** and log in as **`admin`**.

To regenerate compose from Terraform user data (optional): `terraform apply -replace=aws_instance.kimai` in the **same AZ** as the EBS volume.

## Troubleshooting

### `Untrusted Host` in logs (`127.0.0.1`, `172.31.x.x`)

- **172.31.x.x** + `ELB-HealthChecker`: ALB health check used the instance IP as `Host` — fixed by expanded `TRUSTED_HOSTS` (VPC IP regex) on disk (see upgrade steps above).
- **127.0.0.1** + `curl`: image health check — include `127.0.0.1` in `TRUSTED_HOSTS` (module default) or rely on ALB health only (compose disables image healthcheck).

### Login returns to `/en/login` (302 loop)

- Use username **`admin`**, not `admin_email`.
- Password is `admin_password` from `terraform.tfvars` (set only on **first** DB init; changing tfvars later does not update the DB user).
- Reset or recreate user via SSM:

  ```bash
  docker compose exec kimai /opt/kimai/bin/console kimai:user:create admin your@email.com ROLE_SUPER_ADMIN 'new-password'
  ```

## Instance replace without losing data

Workflows and MySQL live on the EBS volume. To replace the instance but keep data:

```bash
terraform apply -replace=aws_instance.kimai
```

Keep `kimai_instance_subnet_id` in the **same Availability Zone** as the existing volume, or Terraform will plan a new volume (data loss risk on destroy).

Verify on the instance:

```bash
docker info | grep "Docker Root Dir"
df -h /data
```

## Backups

This module does **not** automate backups. Recommended operator steps:

1. Create **EBS snapshots** of `kimai_data_volume_id` on a schedule (AWS Backup or manual).
2. Test restore in a non-production environment before relying on snapshots.
3. Export critical Kimai data periodically if required by your policy.

## Plugins and `local.yaml`

Not configured in v1. To add plugins later, bind-mount `/opt/kimai/var/plugins` or add `local.yaml` per [Kimai Docker Compose docs](https://www.kimai.org/documentation/docker-compose.html).

## Cleanup

```bash
terraform destroy
```

Understand EBS and snapshot implications before destroying.

## Verification checklist

After deploy:

- [ ] `terraform validate` succeeds
- [ ] ALB target healthy on port 8001
- [ ] HTTPS loads Kimai at `kimai_hostname`
- [ ] Admin login works (username `admin`)
- [ ] No recurring `Untrusted Host` errors from `ELB-HealthChecker` in `docker compose logs kimai`
- [ ] MySQL port 3306 not reachable from the internet
- [ ] SSM session works; `docker compose ps` shows `kimai` and `sqldb`
- [ ] Data persists after `terraform apply -replace=aws_instance.kimai` (same AZ)

## Repository layout

```text
├── main.tf
├── variables.tf
├── outputs.tf
├── versions.tf
├── terraform.tfvars.example
├── templates/
│   ├── env.tmpl
│   ├── docker-compose.yml.tmpl
│   └── user_data.sh.tmpl
└── README.md
```

## References

- [Kimai](https://www.kimai.org/)
- [Kimai Docker](https://www.kimai.org/documentation/docker.html)
- [Kimai Docker Compose](https://www.kimai.org/documentation/docker-compose.html)
- [kimai/kimai2 on Docker Hub](https://hub.docker.com/r/kimai/kimai2)
- [n8n-terraform](https://github.com/hayzem/n8n-terraform)
