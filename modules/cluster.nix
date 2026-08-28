#
# nixshare's cluster surface: declare which of the byte-moving applications run in the cluster, and
# render them.
#
# ── THIS MODULE DOES NOT IMPLEMENT KUBERNETES, AND THAT IS THE DESIGN ──────────────────────────
#
# A sibling repository's whole subject is the app grammar: a workload declares WHAT IT NEEDS -- an
# image, ports, an exposure class, whether it may sleep, which directories it writes and what backs
# them -- and that grammar renders the Argo CD Application, the Namespace, the Deployment and the
# Service. Everything expressible in those terms is expressed in them: this module DEFINES INTO
# `nixk3s.apps` and renders no Kubernetes object of its own.
#
# So it is a translator. What it adds is the one thing the grammar cannot know: what these
# particular applications ARE. Which of them may be pointed at a directory that does not exist yet
# and which is silently destroyed by that; which must prove its backing writable before it starts;
# which of them can be allowed to sleep and which stops being itself at zero replicas.
#
# IMPORT THE GRAMMAR ALONGSIDE IT. `nixk3s.apps` is declared there, not here, and a render that
# composes this module without it fails with "the option `nixk3s.apps' does not exist".
#
# ── THE OTHER HALF OF THIS REPOSITORY ──────────────────────────────────────────────────────────
#
# `nixshare.shares` mounts somebody else's filesystem here. This is the same act from the other
# end: a server that hands a filesystem out. The options share a namespace because the subject is
# one subject, and they never meet in one evaluation -- these are nixidy modules and those are
# host modules.
#
# ── THE KNOWLEDGE/VALUE SPLIT, ENFORCED RATHER THAN TRUSTED ────────────────────────────────────
#
# `lib/applications.nix` holds what is true of the software anywhere. A declaration holds what is
# true of one cluster. The two cannot supply each other's half, in either direction:
#
#   - the catalogue says WHERE inside the container a directory lives; only a declaration can say
#     WHAT BACKS IT, so a workload that writes a database and is declared without a backing is
#     refused rather than quietly rendered onto a pod's ephemeral filesystem;
#   - the catalogue says WHICH ENVIRONMENT VARIABLE a credential is read from; only a declaration
#     can say which Secret holds it, so a gateway whose root keys were forgotten is refused rather
#     than started with none;
#   - the catalogue says whether a directory MAY BE CREATED EMPTY, and the consumer is not asked,
#     because that is a fact about the software and getting it wrong is silent in both directions;
#   - the catalogue says WHAT THE PROCESS NEEDS FROM THE KERNEL and the consumer is not asked that
#     either, because "this software needs no Linux capability" is a property of the software; what
#     a consumer decides is how much COMPUTE to give it, which is a statement about one cluster's
#     appetite and appears nowhere in the catalogue.
{ mkConsumerModule }:
{ lib, ... }:

let
  catalogue = (import ../lib/applications.nix { }).applications;

  # A whole reference wins over a repository plus a tag, which is what pinning by digest looks
  # like. The catalogue never carries either: a version is a deployment's choice and a digest is
  # one deployment's proof of what it is running.
  imageOf = entry: w: if w.image != null then w.image else "${entry.image}:${w.version}";

  # The split in one function. WHERE inside the container comes from the catalogue; WHAT BACKS IT
  # comes from the declaration; and `hostPathType` comes from the catalogue too, because "may this
  # software be pointed at a directory that does not exist yet" is a property of the software and
  # not of the cluster. That is the one term this module takes AWAY from the consumer, on purpose:
  # every wrong answer to it is silent, and the person writing a declaration has no way to know it.
  stateOf = entry: w:
    lib.mapAttrs
      (key: backing:
        {
          mountPath = entry.state.${key};
          inherit (backing) claim hostPath readOnly;
        }
        // lib.optionalAttrs (backing.hostPath != null) {
          hostPathType =
            if lib.elem key entry.mayStartEmpty then "DirectoryOrCreate" else "Directory";
        })
      w.state;

  # THE COMMAND LINE, in three parts and one order. The catalogue holds the flags the software
  # always takes AND the positional words it must end with; a declaration's own arguments go
  # between them. Appending everything to one list would put a deployment's flag after a positional
  # argument, which is a different command line and, for anything that reads its operands off the
  # end of argv, not a valid one.
  argsOf = entry: w: entry.args ++ w.args ++ entry.trailingArgs;

  # WHAT MAY BE TAKEN AWAY FROM THE PROCESS, derived from what the catalogue says it needs. Two
  # facts about the software become two restrictions on the container, and neither is a policy this
  # module invents: an application that needs no capability can be given none, and one that runs no
  # setuid helper can be forbidden to gain privileges.
  #
  # An application whose privileges are NOT ESTABLISHED renders no securityContext at all -- not an
  # empty one, and not a guessed one. That is the difference between "we know it needs nothing" and
  # "nobody has looked", and only the first is safe to enforce on a running pod.
  securityOf = entry:
    lib.optionalAttrs (entry.privileges != null) {
      security =
        lib.optionalAttrs (!entry.privileges.escalates) { allowPrivilegeEscalation = false; }
        // lib.optionalAttrs (!entry.privileges.needsCapabilities) { capabilitiesDrop = [ "ALL" ]; };
    };

  # HOW MUCH OF ONE CLUSTER THIS WORKLOAD MAY HAVE. Entirely the declaration's: the catalogue knows
  # what the software does, not what it costs on somebody's hardware, and the same gateway is a
  # rounding error on one box and the whole box on another. Only cpu and memory, because everything
  # else a container can request -- a device plugin's resource name above all -- is the NAME of
  # something a particular cluster installed, and this repository writes no fleet facts down.
  resourcesOf = w:
    let
      pick = field: lib.filterAttrs (_: v: v != null) {
        cpu = w.resources.cpu.${field};
        memory = w.resources.memory.${field};
      };
    in
    { requests = pick "request"; limits = pick "limit"; };

  # Prove the backing is writable before the process starts, for the directories the catalogue says
  # need it. It runs the APP'S OWN IMAGE -- a probe compiled against a different build is a probe
  # of something else -- and mounts only the volumes it is meant to touch, which is why the mount
  # keys come from the catalogue rather than from a hand-written list that could name any of them.
  probeScriptFor = entry:
    "set -e; " + lib.concatMapStringsSep " "
      (key:
        let path = entry.state.${key}; in
        "t=${path}/.nixshare-write-probe; touch \"$t\"; rm -f \"$t\"; echo 'writable: ${path}';")
      entry.writeProbe;

  initOf = entry: w:
    lib.optionals (entry.writeProbe != [ ]) [
      {
        name = "write-probe";
        image = imageOf entry w;
        command = [ "/bin/sh" "-c" (probeScriptFor entry) ];
        mounts = lib.listToAttrs
          (map (key: lib.nameValuePair key [{ mountPath = entry.state.${key}; }]) entry.writeProbe);
      }
    ];

  # A credential the catalogue names and a Secret the declaration names, meeting at the variable
  # the process actually reads. Nothing here can carry a secret's CONTENT, which is what makes a
  # declaration written against this module safe to publish.
  credentialsOf = w:
    lib.mapAttrs (_: c: { inherit (c) secret; env = c.keys; }) w.credentials;

  # Whole Secrets, loaded wholesale, for the ones this repository does not catalogue -- a
  # deployment's own additions rather than anything the software demands.
  extraSecretsOf = w:
    lib.listToAttrs (map (s: lib.nameValuePair s { secret = s; envFrom = true; }) w.envFromSecrets);

  # Variables THIS DEPLOYMENT adds out of Secrets the catalogue knows nothing about, named one by
  # one. The middle term between `credentials` (the catalogue says the software reads it) and
  # `envFromSecrets` (whatever the Secret happens to hold): a deployment that grows its own tooling
  # around an application -- a tenant identity, a reconciler's key -- needs the variables to exist
  # and still has no business loading a Secret wholesale.
  #
  # DECLARED PER VARIABLE, REGROUPED PER SECRET. A variable is what a process reads and is the unit
  # somebody actually knows; a Secret reference is how a pod spec spells it, and that regrouping is
  # this module's job rather than the declaration's.
  secretEnvOf = w:
    lib.mapAttrs
      (_: pairs: { env = lib.listToAttrs (map (p: lib.nameValuePair p.name p.value.key) pairs); })
      (lib.groupBy (p: p.value.secret) (lib.mapAttrsToList lib.nameValuePair w.secretEnv));

  secretsOf = w: credentialsOf w // extraSecretsOf w // secretEnvOf w;

  # The factory owns the common projection and all cross-root accounting. This bounded adapter
  # replaces only the fields whose legacy public shapes are intentionally not the factory's common
  # ones: state, role-shaped credentials, nested resources, the write-probe init, positional-tail
  # argument ordering, and this catalogue's established privilege record.
  mkApp = x:
    let inherit (x) app entry w; in
    app
    // {
      state = stateOf entry w;
      init = initOf entry w;
      secrets = secretsOf w;
      args = argsOf entry w;
      resources = resourcesOf w;
      security = (securityOf entry).security or { };
    };

  sorted = lib.sort (a: b: a < b);

  # ── Assertions ────────────────────────────────────────────────────────────────────────────────

  stateAssertions = workloads: lib.concatMap
    (x:
      let inherit (x) name w entry; in
      [
        {
          assertion = lib.attrNames w.state == lib.attrNames entry.state;
          message =
            "nixshare: application `${name}` must back every directory it writes, and backs "
            + (if w.state == { } then "none" else lib.concatMapStringsSep ", " (k: "`${k}`") (lib.attrNames w.state))
            + ". It writes: "
            + (if entry.state == { } then "nothing"
            else lib.concatStringsSep ", " (lib.mapAttrsToList (k: p: "`${k}` at ${p}") entry.state))
            + ".";
        }
        {
          assertion = lib.all
            (backing: (backing.claim == null) != (backing.hostPath == null))
            (lib.attrValues w.state);
          message =
            "nixshare: application `${name}` must back each directory with EITHER an existing claim OR a "
            + "node path, never both and never neither. A directory with no backing is a pod's own "
            + "filesystem, discarded on the next restart -- which for everything catalogued here is "
            + "the whole of what the application was holding.";
        }
      ])
    workloads;

  credentialAssertions = workloads: lib.concatMap
    (x:
      let inherit (x) name w entry; in
      [
        {
          assertion = lib.attrNames w.credentials == lib.attrNames entry.credentials;
          message =
            "nixshare: application `${name}` must be given every credential it reads, and was given "
            + (if w.credentials == { } then "none" else lib.concatMapStringsSep ", " (k: "`${k}`") (lib.attrNames w.credentials))
            + ". It reads: "
            + (if entry.credentials == { } then "none"
            else
              lib.concatStringsSep ", " (lib.mapAttrsToList
                (k: vars: "`${k}` (${lib.concatStringsSep ", " vars})")
                entry.credentials))
            + ". A credential nothing supplies is not a smaller deployment; it is one that starts "
            + "with the door open.";
        }
      ]
      ++ lib.mapAttrsToList
        (bundle: c: {
          assertion = !(entry.credentials ? ${bundle})
          || sorted (lib.attrNames c.keys) == sorted entry.credentials.${bundle};
          message =
            "nixshare: application `${name}` must map exactly the variables its `${bundle}` credential "
            + "is read from, and maps "
            + (if c.keys == { } then "none" else lib.concatMapStringsSep ", " (k: "`${k}`") (sorted (lib.attrNames c.keys)))
            + ". It reads: "
            + lib.concatMapStringsSep ", " (v: "`${v}`") (sorted (entry.credentials.${bundle} or [ ]))
            + ". A variable the process never reads is a key handed out for nothing, and a missing "
            + "one fails at the first request rather than at eval.";
        })
        w.credentials)
    workloads;

  # WHETHER SLEEPING IS SAFE IS KNOWLEDGE; whether it is WANTED is a deployment's call. So this is
  # the one scaling question that refuses rather than warns: for two of the three applications
  # catalogued here, zero replicas does not mean "idle", it means "not doing the thing it exists to
  # do", and no wake front fixes that because nothing that needs them speaks HTTP to a proxy.
  idleAssertions = workloads: map
    (x:
      let inherit (x) name w entry; in
      {
        assertion = w.scaling != "scale-to-zero" || entry.mayIdle;
        message =
          "nixshare: application `${name}` is declared scale-to-zero, and `${w.app}` must not idle. "
          + "It is not a workload that sits still between requests: at zero replicas the work it "
          + "exists to do simply stops, and a wake front cannot help because what needs it does not "
          + "arrive as an HTTP request somebody is holding.";
      })
    workloads;

  secretNameAssertions = workloads: map
    (x:
      let inherit (x) name w; in
      {
        assertion = lib.intersectLists (lib.attrNames w.credentials) w.envFromSecrets == [ ];
        message =
          "nixshare: application `${name}` names one Secret twice -- as a catalogued credential and "
          + "again as a wholesale `envFromSecrets` load ("
          + lib.concatMapStringsSep ", " (k: "`${k}`")
            (lib.intersectLists (lib.attrNames w.credentials) w.envFromSecrets)
          + "). The second definition would silently replace the first, so the named variables would "
          + "quietly become whatever the Secret happens to contain.";
      })
    workloads;

  # A Secret reaches the pod under ONE reference or the module silently keeps the last definition of
  # it: the grammar keys its secrets by a local name, and this module builds those keys from three
  # different places -- a catalogued credential's bundle name, a wholesale load's Secret name, and
  # a `secretEnv` entry's Secret name. Two of them landing on one key is not a merge.
  secretEnvNameAssertions = workloads: map
    (x:
      let
        inherit (x) name w;
        keyed = lib.unique (lib.mapAttrsToList (_: e: e.secret) w.secretEnv);
        clash = lib.intersectLists keyed (lib.attrNames w.credentials ++ w.envFromSecrets);
      in
      {
        assertion = clash == [ ];
        message =
          "nixshare: application `${name}` names Secret "
          + lib.concatMapStringsSep ", " (k: "`${k}`") clash
          + " in `secretEnv` and again as a catalogued credential or a wholesale `envFromSecrets` "
          + "load. One reference would silently replace the other, so the variables somebody wrote "
          + "down would quietly become whichever definition happened to win.";
      })
    workloads;

  # `secretEnv` is for what this DEPLOYMENT adds. A variable the catalogue already says the software
  # reads has an owner, and it is not the declaration: redefining it there is a deployment deciding
  # what the process reads its root credential out of, which is the half this repository holds.
  secretEnvVarAssertions = workloads: lib.concatMap
    (x:
      let
        inherit (x) name w entry;
        catalogued = lib.concatLists (lib.attrValues entry.credentials);
        clash = lib.intersectLists (lib.attrNames w.secretEnv) catalogued;
      in
      [{
        assertion = clash == [ ];
        message =
          "nixshare: application `${name}` adds "
          + lib.concatMapStringsSep ", " (k: "`${k}`") clash
          + " through `secretEnv`, and the catalogue already says the application reads it as one "
          + "of its own credentials. That variable arrives through `credentials`, where the "
          + "catalogue can check that every one the process reads is supplied and no other is.";
      }])
    workloads;

  # A warning is `{ when; message; }` -- the renderer decides whether to print it, so the condition
  # travels with the text rather than being applied here.
  warnings = workloads: lib.concatMap
    (x:
      let inherit (x) name w; in
      [{
        when = w.scaling == "scale-to-zero" && w.wake == null;
        message =
          "nixshare: application `${name}` is declared scale-to-zero with no wake front, so nothing "
          + "brings it back. At zero replicas that is not an idle workload, it is an unreachable one.";
      }])
    workloads;

  commonOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to render this workload. Declaring the attribute is declaring the workload, so this
        defaults to true; set false to park a declaration without rendering it.
      '';
    };

    objectName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        THE NAME THE RENDERED OBJECTS CARRY, when it is not the name this declaration is keyed by.
        Null (the default) names them after the key, which is what a new workload wants.

        IT EXISTS FOR OBJECTS THAT ALREADY EXIST. A Deployment's selector is immutable and a
        Service's endpoints follow the name, so a cluster that has been running this application
        under some older name cannot be renamed onto a tidier one without deleting and recreating
        it -- which for everything catalogued here means the thing stops while it happens. What a
        live object is called is one deployment's history, so this is a value and not knowledge:
        the catalogue never learns that somebody's gateway is called something else.
      '';
    };

    adopt = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        WHETHER THE RENDERED APPLICATION TAKES OVER OBJECTS THAT ALREADY EXIST, by asking the
        delivery layer for server-side apply and server-side diff instead of comparing against a
        client-side reconstruction of what is live. Defaults to false, which is what a workload
        nothing has run yet wants.

        IT IS A VALUE AND NOT KNOWLEDGE, for the same reason `objectName` is. Whether an object is
        already in a cluster is that cluster's HISTORY -- applied by an addon, by hand, by a
        manifest this declaration replaces -- and not a property of the software. The same
        application is adopted on the cluster that has been running it and created from nothing on
        the next one, and it differs here and nowhere else; the catalogue never learns either
        answer.

        IT SHRINKS THE DIFF, IT DOES NOT ERASE IT. A rendered spec is never byte-identical to the
        YAML it replaces -- labels differ, fields this grammar sets appear, fields it does not set
        disappear -- and for everything catalogued here durable state forces `Recreate`: the old
        pod stops before the new one starts, so a diff is downtime rather than a rollout nobody
        notices. Render it, diff it against what is live, and decide knowingly.
      '';
    };

    createNamespace = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this workload anchors its namespace. Defaults to false, because a namespace outlives
        every workload in it and exactly one of them may own it -- and because a namespace that
        holds durable state is the last thing that should be created as a side effect.
      '';
    };

    slot = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      description = ''
        THE POSITION this workload holds in the fleet's ordered identity space. Not an address --
        the layers underneath map it into however many address spaces the fleet keeps, which is
        why nothing here moves one. The VALUE is a fleet fact and belongs to the consumer.
      '';
    };

    exposure = lib.mkOption {
      type = lib.types.enum [ "internal" "nb" "public" ];
      default = "internal";
      description = ''
        Who can reach it, as a CLASS rather than an address. Defaults to the closed answer, and for
        this repository's subject that default earns its keep: everything catalogued here hands out
        somebody's files, and one of them administers the sharing as well.
      '';
    };

    scaling = lib.mkOption {
      type = lib.types.enum [ "always" "scale-to-zero" ];
      default = "always";
      description = ''
        Whether the workload may idle to zero replicas.

        The catalogue records whether sleeping is SAFE for a given application, and declaring
        scale-to-zero for one it says must not idle is refused rather than warned about -- unlike
        every other scaling question here, that one has an answer this repository knows.
      '';
    };

    wake = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "keda" "sablier" ]);
      default = null;
      description = ''
        Which front wakes it from zero. Meaningless unless `scaling = "scale-to-zero"`, and its
        absence there is warned about: nothing brings the workload back.
      '';
    };

    state = lib.mkOption {
      default = { };
      description = ''
        What backs each directory the catalogue says this application writes, keyed by the SAME
        names. Backing a directory it does not write, or leaving one it does write unbacked, is an
        eval error rather than a surprise at runtime.

        THERE IS NO `hostPathType` HERE, and its absence is deliberate: whether this software may be
        pointed at a directory that does not exist yet is a fact about the software, and the
        catalogue answers it. Every wrong answer to that question is silent.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          claim = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              An existing PersistentVolumeClaim, by name. Nothing here creates one -- which for this
              repository's subject is the point rather than a limitation: a freshly provisioned
              claim is an EMPTY directory, and for two of the three applications catalogued here an
              empty directory is not a fresh start but a destroyed identity.
            '';
          };
          hostPath = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "A directory on the node. Pins the workload to whichever node holds it.";
          };
          readOnly = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether the mount is read-only.";
          };
        };
      });
    };

    credentials = lib.mkOption {
      default = { };
      description = ''
        WHICH SECRET holds each credential the catalogue says this application reads, keyed by the
        SAME names. The catalogue names the environment variables the process reads; a declaration
        names the Secret and the key inside it. Neither half can supply the other's, and a missing
        one is an eval error rather than an application that comes up with no credential at all.
      '';
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          secret = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = ''
              NAME of an existing Secret. Named rather than carried: nothing in this repository can
              hold a secret's contents, which is what makes a declaration written here publishable.
            '';
          };
          keys = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            example = lib.literalExpression ''{ EXAMPLE_ACCESS_KEY = "access-key"; }'';
            description = ''
              `<VARIABLE> = "<key in the Secret>"`, for exactly the variables the catalogue says
              this credential is read from. More or fewer is an eval error: a variable the process
              never reads is a key handed out for nothing.
            '';
          };
        };
      }));
    };

    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Environment this deployment adds, merged over whatever the catalogue sets. Values only --
        anything secret belongs in a Secret and arrives through `credentials` or `envFromSecrets`.
      '';
    };

    envFromSecrets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Secrets loaded WHOLESALE, by name, for what this repository does not catalogue -- a
        deployment's own additions rather than anything the software demands. Blunt on purpose: the
        application gets whatever the Secret happens to contain, so a key added later lands in its
        environment unannounced. Anything the catalogue knows about belongs in `credentials`.
      '';
    };

    secretEnv = lib.mkOption {
      default = { };
      example = lib.literalExpression ''
        { EXAMPLE_TENANT_KEY = { secret = "example-tenant"; key = "access-key"; }; }
      '';
      description = ''
        VARIABLES THIS DEPLOYMENT ADDS out of Secrets the catalogue knows nothing about, keyed by
        the variable and named one at a time. The middle term between the two that already exist:
        `credentials` is for what the catalogue says the SOFTWARE reads, and `envFromSecrets` hands
        over whatever a Secret happens to contain.

        It is for the tooling a deployment grows AROUND an application -- a tenant identity below
        the root credential, a reconciler's own key -- which is real, is nobody else's business, and
        still does not justify loading a Secret wholesale. Naming a variable the catalogue already
        holds is an eval error: that one arrives through `credentials`, where it is checked.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          secret = lib.mkOption {
            type = lib.types.str;
            description = "NAME of an existing Secret. Named rather than carried, exactly like `credentials`.";
          };
          key = lib.mkOption {
            type = lib.types.str;
            description = "Key inside that Secret whose value this variable takes.";
          };
        };
      });
    };

    resources = lib.mkOption {
      default = { };
      description = ''
        HOW MUCH OF ONE CLUSTER this workload may have. Entirely a deployment's, and the clearest
        case of it in this whole surface: the catalogue knows what the software does, not what it
        costs on somebody's hardware, and the same gateway is a rounding error on one machine and
        the whole of another. Unset renders nothing, which is a workload the scheduler places as if
        it were free.

        ONLY CPU AND MEMORY. Everything else a container can ask for is the NAME of something a
        particular cluster installed -- a device plugin's resource above all -- and this repository
        writes no fleet facts down. A request is what the scheduler must find; a limit is a ceiling,
        and the two are not the same statement: a memory limit is a kill threshold, a cpu limit is
        a throttle that slows a workload nothing else on the node is competing with.
      '';
      type = lib.types.submodule {
        options = {
          cpu = lib.mkOption {
            default = { };
            description = "Processor time, in Kubernetes' own units (`50m` is a twentieth of a core).";
            type = lib.types.submodule {
              options = {
                request = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  example = "50m";
                  description = "What the scheduler must find for this workload.";
                };
                limit = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = ''
                    A ceiling, enforced as a THROTTLE rather than a kill. Usually the wrong term to
                    reach for: it slows the workload even on an idle node.
                  '';
                };
              };
            };
          };
          memory = lib.mkOption {
            default = { };
            description = "Memory, in Kubernetes' own units (`64Mi`).";
            type = lib.types.submodule {
              options = {
                request = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  example = "64Mi";
                  description = "What the scheduler must find for this workload.";
                };
                limit = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  example = "512Mi";
                  description = "A ceiling, enforced as a KILL. What you want for anything that leaks.";
                };
              };
            };
          };
        };
      };
    };

    args = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Arguments this deployment adds. They land AFTER the flags the catalogue sets and BEFORE the
        positional words it says the command line must end with, because that is the only place an
        added flag can go for software that reads its operands off the end of argv.
      '';
    };

    image = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        A whole image reference, overriding the catalogue's repository and this workload's version.
        This is where a digest pin goes, and pinning by digest is what makes two syncs of an
        identical rendered tree run identical code.
      '';
    };
  };

  factoryModule = mkConsumerModule {
    namespace = "nixshare";

    roots.applications = {
      inherit catalogue;

      # The factory owns the selector option and its enum. Its generic selector description and
      # the absence of the old root-level example are documentation-only deltas: current factory
      # roots intentionally reject an `extraOptions.app` overlay.
      selector = "app";

      # These are the terms whose public shape is already the factory's. The remaining legacy terms
      # below deliberately replace a common name through `extraOptions`: the factory consequently
      # emits no generic state, credentials, or resources and does not inspect those incompatible
      # records. `image` and `wake` are replaced as well so nixshare does not acquire the factory's
      # generic whole-image and wake warnings. Slot remains common: the factory is its single
      # collision and missing-origin authority, avoiding two warnings for one declaration.
      enabledOptions = [
        "version"
        "objectName"
        "adopt"
        "namespace"
        "createNamespace"
        "project"
        "slot"
        "exposure"
        "scaling"
        "env"
        "args"
      ];

      # Enabled common refinements: enable, version, objectName, adopt, createNamespace, slot,
      # exposure, scaling, env, and args. Disabled common replacements: image, wake, state,
      # credentials, and resources. `envFromSecrets` and `secretEnv` are the only genuinely extra
      # names. Namespace and project use the factory declarations unchanged.
      extraOptions = commonOptions // {
        version = lib.mkOption {
          type = lib.types.str;
          description = "Which version this workload runs, used as the image tag. Required, and defaulted nowhere.";
        };
      };

      extend = mkApp;

      assertions = workloads:
        stateAssertions workloads
        ++ credentialAssertions workloads
        ++ idleAssertions workloads
        ++ secretNameAssertions workloads
        ++ secretEnvNameAssertions workloads
        ++ secretEnvVarAssertions workloads;

      inherit warnings;

      description = ''
        The byte-moving applications that run in the cluster, keyed by a name of your choosing.

        THE ENUM IS THE HOUSE RULE. It is built from `lib/applications.nix`, so an application this
        repository does not catalogue is not a refused value here -- it is not a value. What belongs
        in that catalogue is software that acts on bytes without reading them: handing a file to
        somebody, serving a tree as objects, keeping two trees the same.
      '';
    };

    # Preserve the existing resolved defaults. The factory deliberately leaves these cluster facts
    # unset in its generic surface; nixshare's long-standing public contract defaults both to its own
    # name, while a consumer definition still wins over these `mkDefault` values.
    extraConfig = _workloads: {
      nixshare.clusterPlatform.namespace = lib.mkDefault "nixshare";
      nixshare.clusterPlatform.project = lib.mkDefault "nixshare";
    };
  };
in
{
  imports = [ factoryModule ];
}
