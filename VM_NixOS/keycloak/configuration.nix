{ config, pkgs, ... }:
{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "keycloak-vm";

  # NAT adapter — gets internet via DHCP
  networking.interfaces.enp0s3.useDHCP = true;

  # Host-Only adapter — static IP for VM-to-VM communication
  networking.interfaces.enp0s8.ipv4.addresses = [{
    address = "192.168.56.10";
    prefixLength = 24;
  }];

  networking.nameservers = [ "8.8.8.8" "1.1.1.1" ];

  users.users.vrash = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    initialPassword = "'";
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
  };

  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
  };

  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 8080 ];

  environment.systemPackages = with pkgs; [
    docker-compose
    curl
    jq
    vim
  ];

  system.stateVersion = "26.05";
}