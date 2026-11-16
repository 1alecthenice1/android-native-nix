# Your own part of the native profile: packages, dotfiles, ssh config, …
{ pkgs, ... }:
{
  home.packages = with pkgs; [
    git
    htop
    python3
  ];
}
