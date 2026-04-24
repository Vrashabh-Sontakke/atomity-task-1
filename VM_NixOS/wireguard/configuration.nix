{ config, pkgs, ... }:
{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "wireguard-vm";

  # NAT adapter — gets internet via DHCP
  networking.interfaces.enp0s3.useDHCP = true;

  # Host-Only adapter — static IP for VM-to-VM communication
  networking.interfaces.enp0s8.ipv4.addresses = [{
    address = "192.168.56.20";
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

  boot.kernelModules = [ "wireguard" ];

  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 8888 ];
  networking.firewall.allowedUDPPorts = [ 51820 ];

  environment.systemPackages = with pkgs; [
    docker-compose
    wireguard-tools
    curl
    jq
    vim
  ];

  system.stateVersion = "26.05";
}