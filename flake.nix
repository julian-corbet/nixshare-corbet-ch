{
  description = "Declarative NFS/CIFS share definitions whose server address resolves through nixnet peer names instead of hardcoded IPs, plus a watchdog that force-unmounts a stuck automount before it hangs the session.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    system-manager.url = "github:numtide/system-manager";
    system-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, system-manager }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      # ---------------------------------------------------------------
      # Core: services.nixshare.{shares,watchdog} schema + the
      # protocol-agnostic watchdog timer/oneshot. Declares NO
      # systemd.mounts/automounts itself -- that's each provider's job
      # (see modules/providers/{nfs,cifs}.nix), since NFS and CIFS mount
      # option shapes genuinely differ. `nixosModules.default = core`
      # so a bare `imports = [ inputs.nixshare.nixosModules.default ]`
      # gets the schema + watchdog with zero providers -- providers are
      # opt-in additional imports, same shape as nixnet/nixpush.
      # ---------------------------------------------------------------
      nixosModules.core = ./modules/core.nix;
      nixosModules.default = self.nixosModules.core;
      nixosModules.nfs-provider = ./modules/providers/nfs.nix;
      nixosModules.cifs-provider = ./modules/providers/cifs.nix;

      # ---------------------------------------------------------------
      # Server side (README's documented "v2 addition"): NFS/CIFS
      # EXPORTING, not just consuming. Genuinely full NixOS service
      # modules (services.nfs.server, services.samba, services.avahi,
      # services.samba-wsdd) with no system-manager equivalent -- these
      # two are nixosModules-only, unlike the client-side providers
      # above. Independent of services.nixshare.{shares,watchdog}/core.nix
      # -- a host can serve without ever importing the client schema, and
      # vice versa.
      # ---------------------------------------------------------------
      nixosModules.nfs-server-provider = ./modules/providers/nfs-server.nix;
      nixosModules.cifs-server-provider = ./modules/providers/cifs-server.nix;

      # ---------------------------------------------------------------
      # Same files, rendered onto system-manager's smaller option
      # surface instead of a real NixOS rebuild -- this is what
      # actually matters for nixshare's own motivating target: a
      # system-manager host (not NixOS). nixshare only
      # ever touches environment.etc, systemd.services/timers/mounts/
      # automounts, and a rendered JSON config -- see README's
      # "Non-NixOS hosts" section for the one caveat worth knowing.
      # ---------------------------------------------------------------
      systemManagerModules.core = ./modules/core.nix;
      systemManagerModules.default = self.systemManagerModules.core;
      systemManagerModules.nfs-provider = ./modules/providers/nfs.nix;
      systemManagerModules.cifs-provider = ./modules/providers/cifs.nix;

      packages = forAllSystems (system:
        let pkgs = pkgsFor system; in
        {
          nixshare-watchdog = pkgs.callPackage ./pkgs/nixshare-watchdog.nix { };
          default = self.packages.${system}.nixshare-watchdog;
        });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
