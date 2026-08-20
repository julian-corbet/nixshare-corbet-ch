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
#     image before the process starts;
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
    state.data.hostPath = "/example/state/objects";
    state.iam.hostPath = "/example/state/objects-iam";
    credentials.root = {
      secret = "example-gateway-root";
      keys = {
        ROOT_ACCESS_KEY = "example-access-key";
        ROOT_SECRET_KEY = "example-secret-key";
      };
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
