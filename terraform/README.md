# Terraform Infrastructure Documentation

This directory contains Terraform code to provision AWS infrastructure for the Keycloak (behind Traefik) and WireGuard deployment.

## Resources Created
- **VPC**: Main network for all resources.
- **Security Groups**:
  - `allow_internal`: Allows all internal traffic within the VPC.
  - `bastion_ssh`: Allows SSH (port 22) from your IP, HTTP (port 80) for Traefik/Keycloak, Keycloak UI (port 8080), and Traefik dashboard (port 8081) from anywhere.
  - `private_ssh`: Allows SSH from the bastion host to private instances.
- **Subnets**: Public and private subnets for resource isolation.
- **EC2 Instances**: Hosts for running Docker Compose services (Keycloak, Traefik, etc.).

## Security Group Inbound Rules
- **Port 22**: SSH from your IP (variable: `my_ip_cidr`).
- **Port 80**: HTTP for Traefik/Keycloak (open to all).
- **Port 8080**: Keycloak UI (open to all).
- **Port 8081**: Traefik dashboard (open to all).

## Usage
1. Edit `terraform.tfvars` to set your variables (e.g., `my_ip_cidr`).
2. Run `terraform init` to initialize the project.
3. Run `terraform apply` to provision resources.
4. Use the output public IP to access services:
   - Keycloak: `http://<public-ip>/`
   - Traefik dashboard: `http://<public-ip>:8081/`

## Notes
- Make sure to destroy resources with `terraform destroy` when done to avoid charges.
- Security groups are open for demo purposes; restrict as needed for production.
