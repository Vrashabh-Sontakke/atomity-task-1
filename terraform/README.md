# Terraform Infrastructure Documentation

This directory contains Terraform code to provision AWS infrastructure for the
Keycloak (behind Traefik) and WireGuard deployment.

## Resources Created

- **VPC**: Main network (`10.0.0.0/16`) for all resources.
- **Internet Gateway + Route Table**: Public internet access for the public subnet.
- **Subnet**: Single public subnet (`10.0.2.0/24`) with auto-assigned public IPs.
- **Key Pair**: SSH key for EC2 access (path set via `var.public_key_path`).
- **Security Groups**:
  - `allow_internal`: Allows all TCP traffic within the VPC CIDR. Used for
    inter-instance communication (e.g., wg-portal → Keycloak OIDC).
  - `bastion_ssh`: Allows SSH (22) and HTTP (80) from your IP, and
    Traefik dashboard (8081) from your IP only. Also allows port 80 from
    the `wireguard` security group for OIDC auth calls.
  - `private_ssh`: Allows SSH (22) from the public subnet CIDR (bastion access).
  - `wireguard`: Allows UDP 51820 (WireGuard tunnel) from anywhere and
    TCP 8888 (wg-portal web UI) from your workstation IP only.
- **EC2 Instances**:
  - `bastion`: Jump host for SSH access. Uses `bastion_ssh` SG.
  - `keycloak`: Runs Keycloak + Traefik via Docker Compose. Uses
    `allow_internal` + `private_ssh` + `bastion_ssh` SGs.
  - `wireguard`: Runs wg-portal via Docker Compose. Uses
    `allow_internal` + `private_ssh` + `wireguard` SGs.

## Security Group Inbound Rules

| Port | Protocol | Source | Purpose |
|------|----------|--------|---------|
| 22 | TCP | `my_ip_cidr` | SSH to bastion and instances |
| 80 | TCP | 0.0.0.0/0 | Keycloak via Traefik (public access) |
| 80 | TCP | `wireguard` SG | OIDC auth calls from wg-portal (redundant given allow_internal, but explicit) |
| 8081 | TCP | `my_ip_cidr` | Traefik dashboard — **your IP only** |
| 51820 | UDP | 0.0.0.0/0 | WireGuard tunnel (must be open to all VPN clients) |
| 8888 | TCP | `my_ip_cidr` | wg-portal web UI — **your IP only** |

> ⚠️ **Port 8080 is intentionally not exposed.** Keycloak runs behind Traefik
> on port 80. Exposing 8080 directly would bypass the proxy and break
> `KC_PROXY: edge` header forwarding.

> ⚠️ **Port 8081 must be restricted to your IP.** The Traefik dashboard
> exposes internal routing config and should never be open to 0.0.0.0/0.

## Security Group to Instance Mapping

| Instance | Security Groups |
|----------|----------------|
| `bastion` | `bastion_ssh` |
| `keycloak` | `allow_internal`, `private_ssh`, `bastion_ssh` |
| `wireguard` | `allow_internal`, `private_ssh`, `wireguard` |

> ⚠️ **Common Terraform gotcha**: Defining a security group resource does not
> apply it anywhere. It must be explicitly listed in the instance's
> `vpc_security_group_ids`. The `wireguard` SG was missing from the wireguard
> instance in early versions of this config, causing ports 8888 and 51820 to
> be unreachable despite the rules being defined.

## Usage

1. Edit `terraform.tfvars`:
```hcl
   my_ip_cidr      = "x.x.x.x/32"
   aws_region      = "ap-south-1"
   ami_id          = "ami-xxxxxxxxxxxxxxxxx"
   public_key_path = "~/.ssh/id_rsa.pub"
```
2. Run `terraform init` to initialize providers.
3. Run `terraform plan` to preview changes.
4. Run `terraform apply` to provision resources.
5. Access services using the output public IPs:
   - Keycloak: `http://<keycloak-public-ip>/`
   - Traefik dashboard: `http://<keycloak-public-ip>:8081/` (your IP only)
   - WireGuard portal: `http://<wireguard-public-ip>:8888/` (your IP only)

## Notes

- Run `terraform destroy` when done to avoid AWS charges.
- This setup uses HTTP only — suitable for testing. For production, add a
  domain and configure TLS via Traefik Let's Encrypt.
- Security groups are intentionally restrictive on admin ports (8081, 8888,
  22). Only `80` and `51820` are open to the public.
- OIDC traffic from wg-portal to Keycloak flows over the VPC private network
  (`allow_internal` SG), so it never leaves AWS.