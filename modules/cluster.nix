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
#     because that is a fact about the software and getting it wrong is silent in both directions.
{ config, lib, ... }:

let
  cfg = config.nixshare;
  platform = cfg.clusterPlatform;
  catalogue = (import ../lib/applications.nix { }).applications;

  declared = lib.filterAttrs (_: w: w.enable) cfg.applications;
  workloads = lib.mapAttrsToList (name: w: { inherit name w; entry = catalogue.${w.app}; }) declared;

  # A whole reference wins over a repository plus a tag, which is what pinning by digest looks
  # like. The catalogue never carries either: a version is a deployment's choice and a digest is
  # one deployment's proof of what it is running.
  imageOf = entry: w: if w.image != null then w.image else "${entry.image}:${w.version}";

  portsOf = entry: lib.mapAttrs (_: p: { inherit (p) number protocol; }) entry.ports;

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

  probesOf = entry:
    lib.optionalAttrs (entry.readiness != null)
      {
        readiness = { port = entry.primaryPort; } // entry.readiness;
      }
    // lib.optionalAttrs (entry.liveness != null) {
      liveness = { port = entry.primaryPort; } // entry.liveness;
    };

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

  secretsOf = w: credentialsOf w // extraSecretsOf w;

  # Handed to the band model only when the consumer says it is part of the render: `origin` and
  # `slot` are ITS terms, and defining them into a render that does not declare them is an eval
  # error rather than a graceful no-op.
  addressingOf = w:
    lib.optionalAttrs (platform.origin != null) {
      origin = platform.origin;
      inherit (w) slot;
    };

  mkApp = x:
    let inherit (x) entry w; in
    {
      inherit (w) namespace createNamespace project exposure scaling;
      image = imageOf entry w;
      ports = portsOf entry;
      state = stateOf entry w;
      init = initOf entry w;
      secrets = secretsOf w;
      env = entry.env // w.env;
      args = entry.args ++ w.args;
      probes = probesOf entry;
    }
    // lib.optionalAttrs (w.wake != null) { inherit (w) wake; }
    // addressingOf w;

  sorted = lib.sort (a: b: a < b);

  # ── Assertions ────────────────────────────────────────────────────────────────────────────────

  stateAssertions = lib.concatMap
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

  credentialAssertions = lib.concatMap
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

  # A namespace outlives every workload in it, so exactly one thing may own it. Two anchors is not a
  # merge, it is two Namespace objects Argo will fight over.
  anchorAssertions =
    let
      anchors = lib.filter (x: x.w.createNamespace) workloads;
      byNs = lib.groupBy (x: x.w.namespace) anchors;
    in
    lib.mapAttrsToList
      (ns: xs: {
        assertion = lib.length xs == 1;
        message =
          "nixshare: namespace `${ns}` is anchored by ${toString (lib.length xs)} applications ("
          + lib.concatMapStringsSep ", " (x: "`${x.name}`") xs
          + "). Exactly one workload may create a namespace.";
      })
      byNs;

  slotAssertions =
    let
      claimed = lib.filter (x: x.w.slot != null) workloads;
      bySlot = lib.groupBy (x: toString x.w.slot) claimed;
    in
    lib.mapAttrsToList
      (slot: xs: {
        assertion = lib.length xs == 1;
        message =
          "nixshare: slot ${slot} is claimed by ${toString (lib.length xs)} applications ("
          + lib.concatMapStringsSep ", " (x: "`${x.name}`") xs
          + "). A slot is one identity in several address spaces at once; two workloads on one number "
          + "is two workloads on one address.";
      })
      bySlot;

  # WHETHER SLEEPING IS SAFE IS KNOWLEDGE; whether it is WANTED is a deployment's call. So this is
  # the one scaling question that refuses rather than warns: for two of the three applications
  # catalogued here, zero replicas does not mean "idle", it means "not doing the thing it exists to
  # do", and no wake front fixes that because nothing that needs them speaks HTTP to a proxy.
  idleAssertions = map
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

  secretNameAssertions = map
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

  # A warning is `{ when; message; }` -- the renderer decides whether to print it, so the condition
  # travels with the text rather than being applied here.
  warnings = lib.concatMap
    (x:
      let inherit (x) name w; in
      [
        {
          when = w.scaling == "scale-to-zero" && w.wake == null;
          message =
            "nixshare: application `${name}` is declared scale-to-zero with no wake front, so nothing "
            + "brings it back. At zero replicas that is not an idle workload, it is an unreachable one.";
        }
        {
          when = w.slot != null && platform.origin == null;
          message =
            "nixshare: application `${name}` claims slot ${toString w.slot}, and "
            + "`nixshare.clusterPlatform.origin` is unset -- so the number is checked for collisions "
            + "inside this repository and by nothing for which RANGE it may come from.";
        }
      ])
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

    namespace = lib.mkOption {
      type = lib.types.str;
      default = platform.namespace;
      defaultText = lib.literalExpression "config.nixshare.clusterPlatform.namespace";
      description = "Namespace this workload lands in.";
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

    project = lib.mkOption {
      type = lib.types.str;
      default = platform.project;
      defaultText = lib.literalExpression "config.nixshare.clusterPlatform.project";
      description = "Delivery project this workload's Application belongs to.";
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

    args = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Arguments appended to whatever the catalogue sets.";
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
in
{
  options.nixshare.clusterPlatform = {
    # BOTH DEFAULTS NAME THIS REPOSITORY, which is the only name it actually has. A namespace and a
    # delivery project are a cluster's own vocabulary, and a public module that guessed at one
    # would be writing somebody else's tenancy into a file it cannot see. Naming itself is at
    # worst useless and never wrong; every real deployment overrides both.
    namespace = lib.mkOption {
      type = lib.types.str;
      default = "nixshare";
      description = "Namespace these applications share unless a declaration says otherwise.";
    };

    project = lib.mkOption {
      type = lib.types.str;
      default = "nixshare";
      description = "Delivery project their Applications belong to unless a declaration says otherwise.";
    };

    origin = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        THE IDENTITY THIS REPOSITORY'S APPS ARE ADDRESSED UNDER, when the render composes the band
        model. A repository naming itself is not a fleet fact; which band that name binds is, and it
        lives in whatever repository owns the fleet. Left null, slots are still checked for
        collisions here and by nothing for range.
      '';
    };
  };

  options.nixshare.applications = lib.mkOption {
    default = { };
    description = ''
      The byte-moving applications that run in the cluster, keyed by a name of your choosing.

      THE ENUM IS THE HOUSE RULE. It is built from `lib/applications.nix`, so an application this
      repository does not catalogue is not a refused value here -- it is not a value. What belongs
      in that catalogue is software that acts on bytes without reading them: handing a file to
      somebody, serving a tree as objects, keeping two trees the same.
    '';
    example = lib.literalExpression ''
      {
        example-share = {
          app = "pingvin";
          version = "0.0.0";
          exposure = "public";
          slot = 42;
          state.data.hostPath = "/example/state/share";
        };
      }
    '';
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options = commonOptions // {
        app = lib.mkOption {
          type = lib.types.enum (lib.attrNames catalogue);
          description = "Which application, from the catalogue. Available: ${lib.concatStringsSep ", " (lib.attrNames catalogue)}.";
        };

        version = lib.mkOption {
          type = lib.types.str;
          description = "Which version this workload runs, used as the image tag. Required, and defaulted nowhere.";
        };
      };
    }));
  };

  # ── Computed, read-only ───────────────────────────────────────────────────────────────────────
  options.nixshare.clusterSlots = lib.mkOption {
    type = lib.types.attrsOf lib.types.ints.unsigned;
    readOnly = true;
    default = lib.listToAttrs
      (map (x: lib.nameValuePair x.name x.w.slot) (lib.filter (x: x.w.slot != null) workloads));
    defaultText = lib.literalExpression "every declared workload that claims a slot";
    description = ''
      workload -> the position it claims. Nothing is rendered from it here: what an address looks
      like is the private layer's business, and this is what that layer reads to build one.
    '';
  };

  config = {
    nixk3s.apps = lib.listToAttrs (map (x: lib.nameValuePair x.name (mkApp x)) workloads);
    nixidy.assertions =
      stateAssertions
      ++ credentialAssertions
      ++ anchorAssertions
      ++ slotAssertions
      ++ idleAssertions
      ++ secretNameAssertions;
    nixidy.warnings = warnings;
  };
}
