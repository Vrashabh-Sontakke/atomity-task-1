output "keycloak_public_ip" {
  value = aws_instance.keycloak.public_ip
}

output "wireguard_public_ip" {
  value = aws_instance.wireguard.public_ip
}
## output "bastion_public_ip" {
##   value = aws_instance.bastion.public_ip
## }

## output "bastion_private_ip" {
##   value = aws_instance.bastion.private_ip
## }
output "keycloak_instance_id" {
  value = aws_instance.keycloak.id
}

output "keycloak_private_ip" {
  value = aws_instance.keycloak.private_ip
}

output "wireguard_instance_id" {
  value = aws_instance.wireguard.id
}

output "wireguard_private_ip" {
  value = aws_instance.wireguard.private_ip
}
