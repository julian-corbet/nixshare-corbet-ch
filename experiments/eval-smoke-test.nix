# Throwaway eval smoke test -- NOT part of the module surface, just used
# during scaffolding to confirm modules/*.nix evaluates cleanly end to end
# (schema, both providers, watchdog render, assertions) before publishing.
# Safe to delete; nothing imports this file.
{ nixpkgs ? <nixpkgs> }:
let
  system = "x86_64-linux";
  eval = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      ../modules/core.nix
      ../modules/providers/nfs.nix
      ../modules/providers/cifs.nix
      {
        services.nixshare = {
          enable = true;
          watchdog.alertCommand = "echo alert:";
          shares.example = {
            protocol = "nfs";
            peer = "storage-host";
            remotePath = "/export/example";
            mountpoint = "/mnt/example";
            cacheSettings = { actimeo = "60"; fsc = "true"; };
          };
          shares.backups = {
            protocol = "cifs";
            peer = "storage-host";
            remotePath = "backups";
            mountpoint = "/mnt/backups";
            credentialsFile = "/run/secrets/nixshare-backups.cred";
          };
        };
      }
    ];
  };
in
{
  assertionsOk = eval.config.system.build.toplevel != null;
  mounts = eval.config.systemd.mounts;
  automounts = eval.config.systemd.automounts;
  watchdogTimer = eval.config.systemd.timers.nixshare-watchdog;
  watchdogService = eval.config.systemd.services.nixshare-watchdog;
  etcFile = eval.config.environment.etc."nixshare/watchdog.json";
}
