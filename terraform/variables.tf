variable "public_key_path" {
  description = "Path to your public SSH key (e.g., ~/.ssh/bastion.pub)"
  type        = string
}
variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "ami_id" {
  description = "AMI ID for EC2 instances (Ubuntu recommended)"
  type        = string
}

variable "my_ip_cidr" {
  description = "Your public IP in CIDR notation for SSH access (e.g., 1.2.3.4/32)"
  type        = string
}
