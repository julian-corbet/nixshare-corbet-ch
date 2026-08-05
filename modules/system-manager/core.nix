# system-manager core: the portable share schema plus Arch package ownership.
{ ... }:
{
  imports = [
    ../core.nix
    ./packages.nix
  ];
}
