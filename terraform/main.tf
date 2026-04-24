terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ─── Network ────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags       = { Name = "main" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags                    = { Name = "public" }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "main-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
  tags = { Name = "public" }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

data "aws_availability_zones" "available" {}

# ─── Key Pair ───────────────────────────────────────────────────────────────

resource "aws_key_pair" "bastion" {
  key_name   = "bastion"
  public_key = file(var.public_key_path)
}

# ─── Security Groups ────────────────────────────────────────────────────────

# Allows all TCP between instances in the VPC (e.g. wg-portal → Keycloak OIDC)
resource "aws_security_group" "allow_internal" {
  name        = "allow_internal"
  description = "Allow internal traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
    description = "All TCP within VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Applied to: bastion, keycloak
# Handles: SSH, HTTP (Keycloak via Traefik), Traefik dashboard
resource "aws_security_group" "bastion_ssh" {
  name        = "bastion_ssh"
  description = "Allow SSH from your IP"
  vpc_id      = aws_vpc.main.id

  # SSH — your IP only
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
    description = "SSH from workstation"
  }

  # HTTP — public, needed for Keycloak via Traefik
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP for Traefik/Keycloak"
  }

  # Traefik dashboard — your IP only, never open to the world
  ingress {
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
    description = "Traefik dashboard - restricted to workstation"
  }

  # Port 8080 intentionally omitted — Keycloak is behind Traefik on port 80.
  # Exposing 8080 directly bypasses the proxy and breaks KC_PROXY: edge.

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Applied to: keycloak, wireguard
# Allows SSH from bastion (any host in the public subnet)
resource "aws_security_group" "private_ssh" {
  name        = "private_ssh"
  description = "Allow SSH from bastion"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [aws_subnet.public.cidr_block]
    description = "SSH from bastion"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Applied to: wireguard only
resource "aws_security_group" "wireguard" {
  name        = "wireguard"
  description = "Allow WireGuard and wg-portal access"
  vpc_id      = aws_vpc.main.id

  # WireGuard tunnel — must be open to all (VPN clients connect from anywhere)
  ingress {
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "WireGuard tunnel"
  }

  # wg-portal web UI — your IP only (it's a VPN admin panel)
  ingress {
    from_port   = 8888
    to_port     = 8888
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
    description = "wg-portal web UI - restricted to workstation"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ─── EC2 Instances ──────────────────────────────────────────────────────────

# Bastion: SSH jump host, also runs Keycloak+Traefik in this setup
resource "aws_instance" "bastion" {
  ami                         = var.ami_id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.bastion_ssh.id]
  key_name                    = aws_key_pair.bastion.key_name
  tags                        = { Name = "bastion" }
}

# Keycloak: runs Keycloak + Traefik via Docker Compose
# Needs >2 GB RAM — t3.small (2GB) is the minimum
resource "aws_instance" "keycloak" {
  ami                         = var.ami_id
  instance_type               = "t3.small" # t3.small risks OOM under load
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
  vpc_security_group_ids = [
    aws_security_group.allow_internal.id, # inter-instance traffic
    aws_security_group.private_ssh.id,    # SSH from bastion
    aws_security_group.bastion_ssh.id,    # HTTP :80, SSH :22, Traefik :8081
  ]
  key_name = aws_key_pair.bastion.key_name
  tags     = { Name = "keycloak" }
}

# WireGuard: runs wg-portal via Docker Compose
resource "aws_instance" "wireguard" {
  ami                         = var.ami_id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
  vpc_security_group_ids = [
    aws_security_group.allow_internal.id, # inter-instance traffic (OIDC calls to Keycloak)
    aws_security_group.private_ssh.id,    # SSH from bastion
    aws_security_group.wireguard.id,      # UDP :51820, TCP :8888
  ]
  key_name = aws_key_pair.bastion.key_name
  tags     = { Name = "wireguard" }
}