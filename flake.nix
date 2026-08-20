{
  description = "Declarative NFS/CIFS share definitions whose server address resolves through nixnet peer names instead of hardcoded IPs, plus a watchdog that force-unmounts a stuck automount before it hangs the session.";

  # THE HOST SIDE OF THIS FLAKE TAKES NOTHING, and that has not changed: `nixshare.shares` and the
  # watchdog are options plus a package, taking `pkgs`/`config`/`lib` from whichever evaluation
  # composes them, so a real host never puts a second nixpkgs -- or a sibling flake's whole input
  # closure -- into its own closure. The two additions below are used by `checks` ALONE; nothing
  # this flake exports reaches into either.
  #
  # They exist because the cluster module has to be evaluated by SOMETHING. `nix flake check`
  # evaluates no module output on its own, so a cluster surface with no renderer to render it
  # through would have been verified by nobody and passed on flake syntax alone.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The renderer the cluster module defines into.
    nixidy = {
      url = "github:arnarg/nixidy";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # THE APP GRAMMAR THIS REPOSITORY CONSUMES, and the point being proven rather than a shortcut:
    # a consumer imports the grammar itself, and this input exists so the checks can render the
    # cluster module through the REAL grammar and assert what comes out -- rather than asserting
    # that a module which merely mentions `nixk3s.apps` evaluates.
    nixk3s = {
      url = "github:julian-corbet/nixk3s-corbet-ch";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixidy.follows = "nixidy";
    };
  };

  outputs = { self, nixpkgs, nixidy, nixk3s }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      # ---------------------------------------------------------------
      # Core: nixshare.{shares,watchdog} schema + the
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
      nixosModules.nfs-provider = ./modules/nixos/nfs.nix;
      nixosModules.cifs-provider = ./modules/nixos/cifs.nix;
      nixosModules.fscache-provider = ./modules/nixos/fscache.nix;

      # ---------------------------------------------------------------
      # Server side (README's documented "v2 addition"): NFS/CIFS
      # EXPORTING, not just consuming. Genuinely full NixOS service
      # modules (services.nfs.server, services.samba, services.avahi,
      # services.samba-wsdd) with no system-manager equivalent -- these
      # two are nixosModules-only, unlike the client-side providers
      # above. Independent of nixshare.{shares,watchdog}/core.nix
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
      systemManagerModules.core = ./modules/system-manager/core.nix;
      systemManagerModules.default = self.systemManagerModules.core;
      systemManagerModules.nfs-provider = ./modules/system-manager/nfs.nix;
      systemManagerModules.cifs-provider = ./modules/system-manager/cifs.nix;
      systemManagerModules.fscache-provider = ./modules/system-manager/fscache.nix;

      # ---------------------------------------------------------------
      # The cluster plane: the same subject performed by a server
      # instead of a mount. `nixshare.shares` makes somebody else's
      # filesystem appear here; these applications hand a filesystem
      # out -- as a link, as an S3 endpoint, as a peer another device
      # reconciles against. It is a TRANSLATOR, not a renderer: it
      # defines into `nixk3s.apps` and emits no Kubernetes object of
      # its own, so the grammar owns every manifest and this repository
      # owns only what these applications ARE. Import the grammar
      # alongside it. Only one module in the class, so `.default` is
      # honest rather than invented.
      # ---------------------------------------------------------------
      nixidyModules.nixshare = ./modules/cluster.nix;
      nixidyModules.default = self.nixidyModules.nixshare;

      # The catalogue, exposed so a consumer can inspect or validate it without re-reading the file.
      lib.applications = (import ./lib/applications.nix { }).applications;

      packages = forAllSystems (system:
        let pkgs = pkgsFor system; in
        {
          nixshare-watchdog = pkgs.callPackage ./pkgs/nixshare-watchdog.nix { };
          nixshare-health = pkgs.callPackage ./pkgs/nixshare-health.nix { };
          default = self.packages.${system}.nixshare-watchdog;
        });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);

      # ---------------------------------------------------------------
      # Regression guard for the sharenfs dataset-name shell-injection
      # fix in modules/providers/nfs-server.nix: `tree` (a `sharenfs`
      # attrset KEY) used to be inlined into a root shell script
      # unescaped, so a declared ZFS dataset name containing `;` or a
      # backtick was root shell injection. The fix is genuinely
      # two-layered (see that module's `safeZfsTreeName` comment):
      #   (a) an eval-time assertion rejects a key outside
      #       `[A-Za-z0-9_.:/-]+` before it goes anywhere -- this is
      #       the type-level-shaped half (attrset KEYS have no
      #       `lib.types` of their own to attach a `strMatching` to, so
      #       an assertion is the closest equivalent NixOS idiom);
      #   (b) `applyScript` itself wraps every interpolation of `tree`
      #       in `lib.escapeShellArg`, independently of (a), so the
      #       generated script stays safe even if (a) is ever bypassed.
      #
      # A PRIOR version of this check asserted ONLY
      # `builtins.tryEval (...).config.system.build.toplevel .success`
      # booleans on a "good" and a "bad" (hostile) name. That is a
      # real test of layer (a) -- but it is BLIND to layer (b): a
      # reviewer reverted `${lib.escapeShellArg tree}` back to bare
      # `${tree}` at BOTH interpolation sites in applyScript (byte
      # identical to the original vulnerable code) and `nix flake
      # check` still reported this guard GREEN, because the hostile
      # name in the "bad" case was rejected by assertion (a) before
      # `system.build.toplevel` ever forced anything -- regardless of
      # whether applyScript itself still escaped it. tryEval success
      # booleans cannot see that difference; only the RENDERED SCRIPT
      # TEXT can.
      #
      # So this check now does BOTH, as two independent assertions:
      #   1. `goodEval`/`badEval` -- unchanged, still proves layer (a)
      #      (assertion rejects the hostile key at eval time, an
      #      ordinary key still evaluates fine).
      #   2. `renderedScript == expectedScript` -- proves layer (b) on
      #      its OWN, independently of (a). Reading
      #      `.config.systemd.services.nfs-shares-apply.script`
      #      directly (never `.system.build.toplevel`) does NOT force
      #      `config.assertions` to be checked (verified by hand: a
      #      hostile key reaches this string completely unmolested,
      #      with no throw), so a hostile name used ONLY for this half
      #      of the check reaches `applyScript`'s actual rendering
      #      exactly as written -- proving the escaping on its own,
      #      the exact layer the silent revert above removed.
      #      `expectedScript` is built independently, from nixpkgs'
      #      own `lib.escapeShellArg`, against the SAME hostile name
      #      and value -- so this is a byte-exact comparison of
      #      RENDERED COMMAND TEXT, not a success/failure boolean.
      #
      # `fileSystems."/"` / `boot.loader.grub.device` below are only
      # there so `system.build.toplevel` evaluates without tripping the
      # unrelated assertions every bare NixOS config carries.
      # ---------------------------------------------------------------
      checks = forAllSystems (system:
        let
          pkgs = pkgsFor system;

          mkNfsServerEval = sharenfs: lib.nixosSystem {
            inherit system;
            modules = [
              ./modules/providers/nfs-server.nix
              {
                fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
                boot.loader.grub.device = "nodev";
                nixshare.server.nfs = {
                  enable = true;
                  domain = "example.com";
                  inherit sharenfs;
                };
              }
            ];
          };

          # ---- layer (a): the eval-time assertion -----------------------
          goodEval = builtins.tryEval
            (mkNfsServerEval { "solid/shares/example" = "rw=@100.64.99.0/24"; }).config.system.build.toplevel;
          badEval = builtins.tryEval
            (mkNfsServerEval { "solid/shares/example; rm -rf /" = "rw=@100.64.99.0/24"; }).config.system.build.toplevel;

          # ---- layer (b): the rendered applyScript text -----------------
          # A hostile dataset name combining a `;` (command separator)
          # AND a backtick (legacy command substitution) -- the two
          # classic shell-injection vectors -- historically proven to
          # actually execute `touch /tmp/PWNED_SEMI` and
          # `touch /tmp/PWNED_TICK` as root against the pre-fix script.
          hostileTree = "solid/shares/x; touch /tmp/PWNED_SEMI; touch `/tmp/PWNED_TICK`";
          hostileVal = "rw=@100.64.99.0/24";

          renderedScript =
            (mkNfsServerEval { "${hostileTree}" = hostileVal; }).config.systemd.services.nfs-shares-apply.script;

          # Independently reconstructed expected rendering -- same shape
          # applyScript is documented to produce, built with nixpkgs' own
          # escaping primitive rather than by calling into the module's
          # own (private, unexported) `applyScript` binding.
          expectedScript =
            "zfs set sharenfs=${lib.escapeShellArg hostileVal} ${lib.escapeShellArg hostileTree} || echo >&2 ${lib.escapeShellArg "nfs-shares: ${hostileTree} not ready, keeping persisted sharenfs"}"
            + "\nzfs share -a || true\n";

          # A crossmnt root must collapse inherited descendant exports before
          # the declared values are applied. This is deliberately separate
          # from the hostile-name case above: that case has no crossmnt token,
          # so it proves the old rendering stays byte-exact while this one
          # proves the new branch is actually present in the rendered unit.
          crossmntTree = "solid/shares";
          crossmntVal = "rw=@100.64.99.0/24,crossmnt";
          explicitChild = "${crossmntTree}/special";
          explicitChildVal = "ro=@100.64.99.0/24";
          crossmntScript =
            (mkNfsServerEval {
              "${crossmntTree}" = crossmntVal;
              "${explicitChild}" = explicitChildVal;
            }).config.systemd.services.nfs-shares-apply.script;
          crossmntContractOk =
            lib.hasInfix "declare -A nfs_declared_trees=()" crossmntScript
            && lib.hasInfix "for tree in ${lib.escapeShellArg crossmntTree}; do" crossmntScript
            && lib.hasInfix ''zfs get -rH -t filesystem -o name,value,source sharenfs "$tree"'' crossmntScript
            && lib.hasInfix ''[ -n "''${nfs_declared_trees[$child]+declared}" ] && continue'' crossmntScript
            && lib.hasInfix ''if [ "$value" != off ] || [ "$source" != local ]; then'' crossmntScript
            && lib.hasInfix "zfs set sharenfs=${lib.escapeShellArg crossmntVal} ${lib.escapeShellArg crossmntTree}" crossmntScript
            && lib.hasInfix "zfs set sharenfs=${lib.escapeShellArg explicitChildVal} ${lib.escapeShellArg explicitChild}" crossmntScript
            && !lib.hasInfix "for tree in" renderedScript;

          # The client contract is deliberately tested separately from the
          # server injection guard above. It proves that importing all three
          # NixOS providers (a) makes both mount helpers/kernel support part
          # of the NixOS generation, (b) enables the native cachefilesd
          # service when an NFS share requests `fsc`, and (c) publishes the
          # matching Arch package intent for system-manager consumers.
          clientEval = lib.nixosSystem {
            inherit system;
            modules = [
              ./modules/core.nix
              ./modules/nixos/nfs.nix
              ./modules/nixos/cifs.nix
              ./modules/nixos/fscache.nix
              {
                fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
                boot.loader.grub.device = "nodev";
                nixshare = {
                  enable = true;
                  fscache.enable = true;
                  shares = {
                    example = {
                      protocol = "nfs";
                      peer = "storage-host";
                      remotePath = "/export/example";
                      mountpoint = "/mnt/example";
                      cacheSettings.fsc = "true";
                    };
                    backup = {
                      protocol = "cifs";
                      peer = "storage-host";
                      remotePath = "backup";
                      mountpoint = "/mnt/backup";
                    };
                  };
                };
              }
            ];
          };

          clientContractOk =
            lib.all (package: lib.elem package clientEval.config.nixshare.archPackages)
              [ "nfs-utils" "cifs-utils" ]
            && !lib.elem "cachefilesd" clientEval.config.nixshare.archPackages
            && lib.elem "cachefilesd" clientEval.config.nixshare.aurPackages
            && clientEval.config.boot.supportedFilesystems ? nfs
            && clientEval.config.boot.supportedFilesystems ? cifs
            && clientEval.config.services.cachefilesd.enable;

          # Nix's flake schema only checks that systemManagerModules are
          # functions. This evaluation runs their actual Arch-facing unit
          # shape through the compatible NixOS module evaluator: package
          # installation stays host-owned, but the selected packages must be
          # made explicit after that host unit, before cachefilesd starts.
          systemManagerClientEval = lib.nixosSystem {
            inherit system;
            modules = [
              ./modules/system-manager/core.nix
              ./modules/system-manager/nfs.nix
              ./modules/system-manager/cifs.nix
              ./modules/system-manager/fscache.nix
              {
                fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
                boot.loader.grub.device = "nodev";
                nixshare = {
                  enable = true;
                  systemManager.packageReconcilerUnit = "host-packages.service";
                  fscache.enable = true;
                  shares = {
                    example = {
                      protocol = "nfs";
                      peer = "storage-host";
                      remotePath = "/export/example";
                      mountpoint = "/mnt/example";
                      cacheSettings.fsc = "true";
                    };
                    backup = {
                      protocol = "cifs";
                      peer = "storage-host";
                      remotePath = "backup";
                      mountpoint = "/mnt/backup";
                    };
                  };
                };
              }
            ];
          };

          systemManagerContractOk =
            lib.all (package: lib.elem package systemManagerClientEval.config.nixshare.archPackages)
              [ "nfs-utils" "cifs-utils" ]
            && !lib.elem "cachefilesd" systemManagerClientEval.config.nixshare.archPackages
            && lib.elem "cachefilesd" systemManagerClientEval.config.nixshare.aurPackages
            && lib.elem "host-packages.service"
              systemManagerClientEval.config.systemd.services.nixshare-package-ownership.after
            && lib.elem "nixshare-package-ownership.service"
              systemManagerClientEval.config.systemd.services.nixshare-cachefilesd-reconcile.requires;

          # ---- the syncthing peer -------------------------------------
          # Deliberately evaluated with NO shares and NO provider modules
          # imported: continuous replication is an alternative to a mount,
          # not an addition to one, so a host that wants only this must be
          # able to declare it without pulling in a mount stack it will
          # never use. The share-less fixture is what proves that -- it
          # would fail outright if the option had been wired through any
          # provider-shaped machinery.
          mkSyncthingEval = enable: lib.nixosSystem {
            inherit system;
            modules = [
              ./modules/core.nix
              {
                fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
                boot.loader.grub.device = "nodev";
                nixshare = { enable = true; syncthing.enable = enable; };
              }
            ];
          };

          syncthingOn = (mkSyncthingEval true).config.nixshare;
          syncthingOff = (mkSyncthingEval false).config.nixshare;

          syncthingContractOk =
            lib.elem "syncthing" syncthingOn.archPackages
            # Not AUR: syncthing is an official-repo package on Arch, and a name in the wrong half
            # of that split is the failure the provider lists already guard against.
            && !lib.elem "syncthing" syncthingOn.aurPackages
            # Off by default, and off means contributing nothing at all -- a host that never
            # mentions this option must not acquire a sync daemon because it wanted an NFS mount.
            && syncthingOff.archPackages == [ ]
            && syncthingOff.syncthing.enable == false;

          healthPackage = pkgs.callPackage ./pkgs/nixshare-health.nix { };
          healthResetBehaviorFixture = pkgs.writeShellApplication {
            name = "nixshare-health-reset-behavior-fixture";
            runtimeInputs = [ pkgs.coreutils pkgs.gawk ];
            text = ''
              ${builtins.readFile ./pkgs/nixshare-health-reset.sh}
              ${builtins.readFile ./tests/nixshare-health-reset-fixture.sh}
            '';
          };
        in
        {
          nixshare-sharenfs-injection-guard =
            if goodEval.success && !badEval.success && renderedScript == expectedScript && crossmntContractOk
            then pkgs.runCommand "nixshare-sharenfs-injection-guard" { } "touch $out"
            else
              throw ''
                nixshare sharenfs injection guard FAILED:
                  (a) ordinary dataset name evaluated ok         = ${lib.boolToString goodEval.success} (expected true)
                  (a) hostile dataset name rejected by assertion = ${lib.boolToString (!badEval.success)} (expected true)
                  (b) rendered applyScript for a hostile name matches
                      the independently-expected, fully-escaped text = ${lib.boolToString (renderedScript == expectedScript)} (expected true)
                  (c) crossmnt rendering collapses inherited descendants
                      before restoring declarations = ${lib.boolToString crossmntContractOk} (expected true)

                --- (b) actual rendered script ---
                ${renderedScript}
                --- (b) expected rendered script ---
                ${expectedScript}
              '';

          nixshare-client-provider-contract =
            if clientContractOk
            then pkgs.runCommand "nixshare-client-provider-contract" { } "touch $out"
            else throw "nixshare client provider contract FAILED";

          nixshare-system-manager-provider-contract =
            if systemManagerContractOk
            then pkgs.runCommand "nixshare-system-manager-provider-contract" { } "touch $out"
            else throw "nixshare system-manager provider contract FAILED";

          nixshare-syncthing-contract =
            if syncthingContractOk
            then pkgs.runCommand "nixshare-syncthing-contract" { } "touch $out"
            else
              throw ''
                nixshare syncthing contract FAILED:
                  enabled  -> archPackages = ${builtins.toJSON syncthingOn.archPackages}, aurPackages = ${builtins.toJSON syncthingOn.aurPackages}
                  disabled -> archPackages = ${builtins.toJSON syncthingOff.archPackages}
              '';

          # Build-time inspection of the actual rendered executable, not the
          # Nix source.  The reachability gate must carry an absolute Bash
          # store path, and every external command used deeper in recovery
          # must be present in the wrapper's own PATH.  A missing awk used to
          # let detection succeed and then abort reset-client after teardown
          # had begun, so checking only the first branch is not enough.
          nixshare-health-clean-path-contract = pkgs.runCommand
            "nixshare-health-clean-path-contract"
            { }
            ''
              if ! grep -F ${lib.escapeShellArg (lib.getExe pkgs.bash)} \
                ${healthPackage}/bin/nixshare-health >/dev/null; then
                echo "rendered nixshare-health does not reference its Bash interpreter absolutely" >&2
                exit 1
              fi
              if ! head -n 8 ${healthPackage}/bin/nixshare-health \
                | grep -F ${lib.escapeShellArg "${pkgs.gawk}/bin"} >/dev/null; then
                echo "rendered nixshare-health PATH does not contain gawk" >&2
                exit 1
              fi
              if ! head -n 8 ${healthPackage}/bin/nixshare-health \
                | grep -F ${lib.escapeShellArg "${pkgs.gnugrep}/bin"} >/dev/null; then
                echo "rendered nixshare-health PATH does not contain gnugrep" >&2
                exit 1
              fi
              if ! grep -F 'ls -U1 --color=never "$mp"' \
                ${healthPackage}/bin/nixshare-health >/dev/null; then
                echo "rendered nixshare-health does not use the names-only directory probe" >&2
                exit 1
              fi
              if ! grep -F 'setpriv --reuid "$probe_uid" --regid "$probe_gid" --init-groups' \
                ${healthPackage}/bin/nixshare-health >/dev/null; then
                echo "rendered nixshare-health cannot probe a root-squashed share as its intended user" >&2
                exit 1
              fi
              if grep -F 'ls -la "$mp"' ${healthPackage}/bin/nixshare-health >/dev/null; then
                echo "rendered nixshare-health still recursively stats the mountpoint listing" >&2
                exit 1
              fi
              touch "$out"
            '';

          nixshare-health-reset-behavior = pkgs.runCommand
            "nixshare-health-reset-behavior"
            { nativeBuildInputs = [ healthResetBehaviorFixture ]; }
            ''
              nixshare-health-reset-behavior-fixture
              touch "$out"
            '';
        }
        # ---------------------------------------------------------------
        # The cluster half, x86_64-linux only and narrow ON PURPOSE. Both
        # checks below build a real nixidy environment, so a declared
        # platform that cannot be built here is a platform `nix flake
        # check` skips while exiting 0 -- a check that passed having
        # tested nothing. The host side above genuinely runs on both
        # architectures and keeps them; narrow the claim rather than
        # weaken the check.
        # ---------------------------------------------------------------
        // lib.optionalAttrs (system == "x86_64-linux") {
          # The cluster module's own resolution and every guard it makes, in BOTH directions: an
          # empty surface renders nothing, a declared one resolves, and each refusal gets a
          # declaration that must be refused.
          cluster-eval = import ./checks/cluster-eval.nix {
            inherit pkgs lib nixidy;
            appsModule = nixk3s.nixidyModules.apps;
            clusterModule = self.nixidyModules.nixshare;
            values = ./examples/all/values.nix;
          };

          # The manifests that actually come out, read back off the rendered bytes rather than off
          # the options that produced them.
          cluster-render = import ./checks/cluster-render.nix {
            inherit pkgs lib nixidy;
            appsModule = nixk3s.nixidyModules.apps;
            clusterModule = self.nixidyModules.nixshare;
            values = ./examples/all/values.nix;
          };
        });
    };
}
