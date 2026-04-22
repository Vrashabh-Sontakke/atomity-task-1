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
