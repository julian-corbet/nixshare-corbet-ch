# Placeholder values for the cluster module — the file that makes the render check real.
# `nix flake check` renders the whole surface from here, so a module that stops evaluating, or that
# grows a required value nobody supplies, fails in CI rather than in somebody's cluster.
#
# NOTHING HERE IS REAL. Every namespace, path, name, number and image is invented for this file, and
# no credential appears in any form — only the NAME of a Secret that would hold one, and the NAME of
# the key inside it.
#
# All three catalogued applications are declared, because they differ in what gets RENDERED rather
# than merely in what evaluates:
#
#   - one that may sleep, anchoring the shared namespace, behind a wake front, writing a single
#     directory it backs on a node path;
#   - one that must not sleep, writing TWO directories with different answers to "may this be
#     created empty", proving a required credential and rendering an init container out of its own
#     image before the process starts -- and, because it is also the one whose command line ends in
#     positional arguments, the one that shows where a deployment's own flag has to land -- under a
#     name its objects already carry rather than the one it is keyed by, and adopting them in place
#     rather than being created, which is the only declaration here whose Application differs;
#   - one that must not sleep either, in a namespace of its own, mixing a claim-backed directory
#     with a node-path one and declaring ports on three protocols.
{
  # Required by the nixidy environment itself, not by any module here.
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  nixshare.clusterPlatform = {
    namespace = "example-shares";
    project = "example-data";
  };

  # Writes one directory holding a database, so it may not roll; backs it on a node path, which is
  # the half the catalogue cannot supply. Sleeps, and names the front that wakes it — without which
  # the module warns that nothing brings it back.
  nixshare.applications.example-share = {
    app = "pingvin";
    version = "0.0.0";
    createNamespace = true;
    exposure = "public";
    slot = 40;
    scaling = "scale-to-zero";
    wake = "keda";
    state.data.hostPath = "/example/state/share";
  };

  # Two directories with opposite answers to whether they may be created empty, one required
  # credential, and a whole image reference so two syncs of an identical tree run identical code.
  # Joins the namespace above rather than anchoring a second one.
  nixshare.applications.example-gateway = {
    app = "versitygw";
    version = "0.0.0";
    image = "registry.example.com/example-org/example-gateway:0.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000";
    exposure = "public";
    slot = 41;

    # THE OBJECTS ARE OLDER THAN THIS DECLARATION and carry a name nothing may rename: a
    # Deployment's selector is immutable, so tidying the name is delete-and-recreate, which for a
    # gateway means the endpoint disappears while it happens. Keyed here by what it IS, rendered
    # under what it is CALLED.
    objectName = "example-gateway-legacy";

    # AND THEY ARE ALREADY RUNNING, which is the other half of the same history: the rendered spec
    # will not be byte-identical to whatever applied them, and a gateway holding a directory is
    # stopped before it is restarted. Server-side apply and diff compare against what the API
    # server actually holds, which is what makes taking the objects over possible at all.
    adopt = true;

    # ONE ADDED FLAG, and the reason `trailingArgs` exists. The catalogue's own flags come first,
    # this lands next, and the positional `posix /data` the gateway reads off the end of argv stays
    # last -- which a single appended list could not do.
    args = [ "--cors-allow-origin" "https://example.com" ];

    # One cluster's appetite, stated nowhere in the catalogue.
    resources = {
      cpu.request = "50m";
      memory = { request = "64Mi"; limit = "512Mi"; };
    };

    state.data.hostPath = "/example/state/objects";
    state.iam.hostPath = "/example/state/objects-iam";
    credentials.root = {
      secret = "example-gateway-root";
      keys = {
        ROOT_ACCESS_KEY = "example-access-key";
        ROOT_SECRET_KEY = "example-secret-key";
      };
    };

    # A TENANT BELOW THE ROOT CREDENTIAL: not something the gateway reads, so the catalogue has no
    # word for it, and still not a reason to load a whole Secret. Named variable by variable.
    secretEnv = {
      EXAMPLE_TENANT_ACCESS_KEY = { secret = "example-gateway-tenant"; key = "example-access-key"; };
      EXAMPLE_TENANT_SECRET_KEY = { secret = "example-gateway-tenant"; key = "example-secret-key"; };
    };
  };

  # Its identity comes from a claim that already exists and its synced tree from a node path — the
  # only declaration here that mixes the two backings, and the one whose namespace it anchors
  # itself, so the anchor guard is exercised per namespace rather than globally.
  nixshare.applications.example-sync = {
    app = "syncthing";
    version = "0.0.0";
    namespace = "example-sync";
    createNamespace = true;
    exposure = "nb";
    slot = 42;
    state.config.claim = "example-sync-identity";
    state.data.hostPath = "/example/state/sync";
    credentials.gui = {
      secret = "example-sync-gui";
      keys.STGUIAPIKEY = "example-api-key";
    };
  };
}
