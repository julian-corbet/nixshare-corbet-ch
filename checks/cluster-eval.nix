# Proves the cluster module resolves what it claims and REFUSES what it claims to refuse, both
# directions, through the real renderer and the real app grammar.
#
# Both halves matter and neither is enough alone. A guard nobody has watched fire is a comment; a
# guard that fires on everything is a wall. So every case below is a complete, otherwise-valid
# surface with exactly one thing wrong, and the `control` case is the same shape with nothing wrong
# and MUST render -- without it, a typo in the shared base would make every other case "pass" for
# the wrong reason.
#
# TWO OF THE REFUSALS ARE NOT GUARDS AT ALL. Naming an application the catalogue does not hold, and
# leaving out the version, fail as a type error and a missing required option -- not as assertions.
# That is the stronger kind: a boundary nobody has to remember, because it is unwritable rather than
# refused. `tryEval` cannot tell those apart from a guard, so the ones that ARE guards additionally
# have their message asserted by content.
#
# THE CATALOGUE IS CHECKED AS WELL AS THE MODULE. Half of what this repository knows lives in a
# data file that nothing else forces: a `primaryPort` naming a port that was renamed, or a
# `writeProbe` on a directory that no longer exists, would evaluate perfectly and describe an
# application nobody runs. Those properties are asserted over EVERY entry rather than the two the
# example surface happens to declare.
{ pkgs, lib, nixidy, appsModule, clusterModule, values }:

let
  base = import values;
  catalogue = (import ../lib/applications.nix { }).applications;

  mkEnv = v: nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ appsModule clusterModule v ];
  };

  # `tryEval` alone forces only WHNF. Forcing the derivation path is what actually runs the module
  # system's type checks and the assertions underneath.
  renders = v: (builtins.tryEval (builtins.seq (mkEnv v).environmentPackage.drvPath true)).success;

  # An assertion fired, AND it is the one meant: a refusal that happens for an unrelated reason is
  # a false pass, which is exactly the failure this repository's checks exist to make impossible.
  failsWith = infix: v:
    let
      r = builtins.tryEval (lib.any
        (a: !a.assertion && lib.hasInfix infix a.message)
        (mkEnv v).config.nixidy.assertions);
    in
    r.success && r.value;

  # A surface with nothing declared at all, to prove the module is inert until something asks.
  emptyCfg = (mkEnv {
    nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
    nixidy.target.branch = "main";
  }).config;

  goodCfg = (mkEnv base).config;

  with' = f: lib.recursiveUpdate base f;

  apps = goodCfg.nixk3s.apps;
  gateway = apps.example-gateway;

  results = {
    # ── The control, and the floor ────────────────────────────────────────────────────────────
    "the example surface renders -- without this every refusal below could pass for the wrong reason" =
      renders base;

    "an undeclared surface renders no apps at all, rather than a default one" =
      emptyCfg.nixk3s.apps == { };

    "all three declared workloads reach the grammar" =
      lib.sort (a: b: a < b) (lib.attrNames apps)
      == [ "example-gateway" "example-share" "example-sync" ];

    # ── What the catalogue supplies, and what it refuses to ───────────────────────────────────
    "the catalogue supplies the ports, and no declaration states one" =
      apps.example-share.ports.http.number == 3000
      && gateway.ports.s3.number == 7070
      && apps.example-sync.ports.webui.number == 8384;

    "a peer protocol is not an HTTP port, and the catalogue says so" =
      apps.example-sync.ports.sync-udp.number == 22000
      && apps.example-sync.ports.sync-udp.protocol == "UDP"
      && apps.example-sync.ports.sync-tcp.protocol == "TCP";

    "a version becomes the tag, and a whole reference overrides it" =
      apps.example-share.image == "stonith404/pingvin-share:0.0.0"
      && lib.hasInfix "@sha256:" gateway.image;

    "the catalogue supplies WHERE a directory lives and the declaration supplies WHAT BACKS IT" =
      apps.example-share.state.data.mountPath == "/opt/app/backend/data"
      && apps.example-share.state.data.hostPath == "/example/state/share"
      && apps.example-sync.state.config.claim == "example-sync-identity";

    # The field this domain grew, read back off the grammar: the consumer never typed either value.
    "whether a directory may be created empty comes from the catalogue, never from the declaration" =
      gateway.state.data.hostPathType == "Directory"
      && gateway.state.iam.hostPathType == "DirectoryOrCreate"
      && apps.example-share.state.data.hostPathType == "Directory";

    "a credential is a variable the catalogue names and a Secret the declaration names" =
      gateway.secrets.root.secret == "example-gateway-root"
      && gateway.secrets.root.env.ROOT_ACCESS_KEY == "example-access-key"
      && gateway.secrets.root.env.ROOT_SECRET_KEY == "example-secret-key";

    "an application the catalogue says reads no credential declares no Secret at all" =
      apps.example-share.secrets == { };

    "the write probe runs the application's OWN image and mounts only what it must prove" =
      lib.length gateway.init == 1
      && (lib.head gateway.init).name == "write-probe"
      && (lib.head gateway.init).image == gateway.image
      && lib.attrNames (lib.head gateway.init).mounts == [ "data" ];

    "an application the catalogue gives no write probe renders no init container" =
      apps.example-share.init == [ ] && apps.example-sync.init == [ ];

    "both probes come from the catalogue, and a bare TCP liveness stays bare" =
      apps.example-share.probes.readiness.path == "/api/configs"
      && apps.example-share.probes.readiness.failureThreshold == 30
      && apps.example-share.probes.liveness.path == null
      && gateway.probes.liveness.timeoutSeconds == 5;

    # ── The catalogue's own integrity, over every entry rather than the declared ones ─────────
    "every catalogued application's primaryPort names a port it declares" =
      lib.all (e: e.ports ? ${e.primaryPort}) (lib.attrValues catalogue);

    "every directory named by mayStartEmpty or writeProbe is one the application writes" =
      lib.all
        (e: lib.all (k: e.state ? ${k}) (e.mayStartEmpty ++ e.writeProbe))
        (lib.attrValues catalogue);

    "the gateway's arguments name the same port and the same directories it declares elsewhere" =
      let e = catalogue.versitygw; in
      lib.elem ":${toString e.ports.${e.primaryPort}.number}" e.args
      && lib.all (p: lib.elem p e.args) (lib.attrValues e.state);

    # ── Unwritable, not merely refused ────────────────────────────────────────────────────────
    "an application the catalogue does not hold is not a value this option has" =
      !renders (with' { nixshare.applications.example-share.app = "nonesuch"; });

    "a workload with no version is refused, because a floating tag is not a default anyone can pick" =
      !renders {
        nixidy.target.repository = "https://example.com/x.git";
        nixidy.target.branch = "main";
        nixshare.applications.x = {
          app = "pingvin";
          state.data.hostPath = "/example/x";
        };
      };

    # ── The guards, each with its message asserted ────────────────────────────────────────────
    "backing a directory the application does not write is refused" =
      failsWith "must back every directory it writes"
        (with' { nixshare.applications.example-share.state.nope.hostPath = "/example/nope"; });

    "leaving a directory it DOES write unbacked is refused" =
      failsWith "must back every directory it writes"
        (lib.recursiveUpdate base { nixshare.applications.example-gateway.state = lib.mkForce { }; });

    "a directory backed by both a claim and a node path is refused" =
      failsWith "EITHER an existing claim OR a node path"
        (with' { nixshare.applications.example-share.state.data.claim = "example-claim"; });

    "forgetting a credential the application reads is refused, not quietly rendered" =
      failsWith "must be given every credential it reads"
        (lib.recursiveUpdate base { nixshare.applications.example-gateway.credentials = lib.mkForce { }; });

    "mapping a variable the process never reads is refused" =
      failsWith "must map exactly the variables"
        (with' { nixshare.applications.example-gateway.credentials.root.keys.NOT_A_VARIABLE = "x"; });

    "naming one Secret as a credential and again as a wholesale load is refused" =
      failsWith "names one Secret twice"
        (with' { nixshare.applications.example-gateway.envFromSecrets = [ "root" ]; });

    "two workloads anchoring one namespace is refused" =
      failsWith "Exactly one workload may create a namespace"
        (with' { nixshare.applications.example-gateway.createNamespace = true; });

    "two workloads on one slot is refused" =
      failsWith "is claimed by 2 applications"
        (with' { nixshare.applications.example-gateway.slot = 40; });

    # ── The scaling question this repository DOES have an answer to ──────────────────────────
    # Everywhere else, whether a workload sleeps is a deployment's call. Here it is not: at zero
    # replicas a gateway is an endpoint that drops writes and a sync client is not synchronising,
    # and no wake front repairs either -- so this one refuses rather than warns.
    "sleeping an application the catalogue says must not idle is refused" =
      failsWith "must not idle"
        (with' { nixshare.applications.example-gateway.scaling = "scale-to-zero"; })
      && failsWith "must not idle"
        (with' { nixshare.applications.example-sync.scaling = "scale-to-zero"; });

    # ── The warning that is not a refusal ─────────────────────────────────────────────────────
    # Sleeping with nothing to wake it is a real mistake and still not an eval error: which front a
    # cluster runs is its own business, and a repository that refused the combination would be
    # legislating routing it cannot see.
    "scale-to-zero with no wake front warns rather than refuses" =
      let cfg = (mkEnv (with' { nixshare.applications.example-share.wake = lib.mkForce null; })).config;
      in lib.any (w: w.when && lib.hasInfix "nothing brings it back" w.message) cfg.nixidy.warnings;
  };

  failed = lib.filter (n: !results.${n}) (lib.attrNames results);
in
pkgs.runCommand "nixshare-cluster-eval" { } (
  if failed == [ ]
  then ''
    echo "nixshare: all ${toString (lib.length (lib.attrNames results))} cluster-eval properties hold"
    touch $out
  ''
  else ''
    echo "nixshare cluster-eval FAILED (${toString (lib.length failed)}/${toString (lib.length (lib.attrNames results))}):" >&2
    ${lib.concatMapStringsSep "\n" (n: ''echo "  - ${n}" >&2'') failed}
    exit 1
  ''
)
