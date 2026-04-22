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

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
}

resource "aws_security_group" "allow_internal" {
  name        = "allow_internal"
  description = "Allow internal traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "keycloak" {
  ami           = var.ami_id 
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.private.id 
  vpc_security_group_ids = [aws_security_group.allow_internal.id] 
  tags = { Name = "keycloak" }
}

resource "aws_instance" "wireguard" {
  ami           = var.ami_id
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.allow_internal.id]
  tags = { Name = "wireguard" }
}

data "aws_availability_zones" "available" {}
