# Reads the catalogue's promises back off the RENDERED BYTES, not off the options that produced
# them.
#
# The eval check proves the module resolves and refuses. This one proves the manifests that come
# out say what the catalogue claims — a different question, and the only one a cluster ever sees.
# An option can be correct and the rendering still wrong.
#
# It matters more here than in a repository of stateless web apps. Almost everything this catalogue
# knows is a fact about a DIRECTORY — where it is mounted, whether the kubelet may create it, which
# container is allowed to touch it — and every one of those facts is a single field buried in a pod
# spec. A wrong one does not fail: it starts, serves, and quietly means something else.
{ pkgs, lib, nixidy, appsModule, clusterModule, values }:

let
  env = nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ appsModule clusterModule (import values) ];
  };
in
pkgs.runCommand "nixshare-cluster-render"
{
  nativeBuildInputs = [ pkgs.yq-go ];
  manifests = env.environmentPackage;
} ''
  set -euo pipefail
  fail=0
  check() { # name expected actual
    if [ "$2" = "$3" ]; then echo "  ok   $1: $3"
    else echo "  FAIL $1: expected '$2', got '$3'"; fail=1; fi
  }
  y() { yq -r "$1" "$2"; }

  echo "== the environment renders all three workloads and nothing else =="
  # The gateway's directory is named `example-gateway-legacy`, not `example-gateway`: it declares an
  # `objectName`, and the objects -- and therefore the rendered path -- take THAT. The declaration
  # is still keyed by what the workload IS, which is what every other option here reads.
  rendered=$(ls "$manifests" | sort | tr '\n' ' ' | sed 's/ $//')
  check "rendered apps" "apps example-gateway-legacy example-share example-sync" "$rendered"

  share="$manifests/example-share"
  gw="$manifests/example-gateway-legacy"
  sync="$manifests/example-sync"

  shareD="$share/Deployment-example-share.yaml"
  gwD="$gw/Deployment-example-gateway-legacy.yaml"
  syncD="$sync/Deployment-example-sync.yaml"

  echo "== the catalogue's ports reach the container, and no declaration stated one =="
  check "share port"   "3000" "$(y '.spec.template.spec.containers[0].ports[0].containerPort' $shareD)"
  check "gateway port" "7070" "$(y '.spec.template.spec.containers[0].ports[0].containerPort' $gwD)"
  check "sync web port" "8384" "$(y '.spec.template.spec.containers[0].ports[] | select(.name == "webui") | .containerPort' $syncD)"

  echo "== a peer protocol is not an HTTP port: two protocols on one number, and a UDP discovery port =="
  check "sync tcp" "TCP" "$(y '.spec.template.spec.containers[0].ports[] | select(.name == "sync-tcp") | .protocol' $syncD)"
  check "sync udp" "UDP" "$(y '.spec.template.spec.containers[0].ports[] | select(.name == "sync-udp") | .protocol' $syncD)"
  check "discovery udp" "UDP" "$(y '.spec.template.spec.containers[0].ports[] | select(.name == "discovery") | .protocol' $syncD)"

  echo "== every one of these is a single writer on a directory, so none of them may roll =="
  for f in $shareD $gwD $syncD; do
    check "$(basename $f) strategy" "Recreate" "$(y '.spec.strategy.type' $f)"
  done
  # An absent `replicas` IS one -- Kubernetes' own default. Asserting it is unset is the honest
  # form: the grammar deliberately does not stamp a count on a workload whose count belongs to its
  # wake front.
  check "sleeping workload has no replica count" "null" "$(y '.spec.replicas' $shareD)"

  echo "== WHERE a directory is mounted comes from the catalogue =="
  check "share mountPath" "/opt/app/backend/data" "$(y '.spec.template.spec.containers[0].volumeMounts[0].mountPath' $shareD)"
  check "gateway data mountPath" "/data" "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "data") | .mountPath' $gwD)"
  check "gateway iam mountPath" "/iam" "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "iam") | .mountPath' $gwD)"
  check "sync identity mountPath" "/config" "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "config") | .mountPath' $syncD)"

  echo "== and WHETHER THE KUBELET MAY CREATE IT does too -- the field that is silent when wrong =="
  check "gateway backend must exist" "Directory" "$(y '.spec.template.spec.volumes[] | select(.name == "data") | .hostPath.type' $gwD)"
  check "gateway iam may be created" "DirectoryOrCreate" "$(y '.spec.template.spec.volumes[] | select(.name == "iam") | .hostPath.type' $gwD)"
  check "share data must exist" "Directory" "$(y '.spec.template.spec.volumes[] | select(.name == "data") | .hostPath.type' $shareD)"
  check "sync tree must exist" "Directory" "$(y '.spec.template.spec.volumes[] | select(.name == "data") | .hostPath.type' $syncD)"

  echo "== a claim-backed volume is a claim and nothing else: no node path, no hostPath type =="
  check "sync identity claim" "example-sync-identity" "$(y '.spec.template.spec.volumes[] | select(.name == "config") | .persistentVolumeClaim.claimName' $syncD)"
  check "sync identity has no node path" "null" "$(y '.spec.template.spec.volumes[] | select(.name == "config") | .hostPath' $syncD)"

  echo "== the write probe runs the app's own image, before it starts, seeing only what it must prove =="
  check "gateway init count" "1" "$(y '.spec.template.spec.initContainers | length' $gwD)"
  check "gateway init name" "write-probe" "$(y '.spec.template.spec.initContainers[0].name' $gwD)"
  check "gateway init image is the app's" "true" \
    "$([ "$(y '.spec.template.spec.initContainers[0].image' $gwD)" = "$(y '.spec.template.spec.containers[0].image' $gwD)" ] && echo true || echo false)"
  check "gateway init mounts" "1" "$(y '.spec.template.spec.initContainers[0].volumeMounts | length' $gwD)"
  check "gateway init sees only the backend" "/data" "$(y '.spec.template.spec.initContainers[0].volumeMounts[0].mountPath' $gwD)"
  check "share has no init container" "null" "$(y '.spec.template.spec.initContainers' $shareD)"
  check "sync has no init container" "null" "$(y '.spec.template.spec.initContainers' $syncD)"

  echo "== a credential is a reference: the variable is in the manifest, the value never is =="
  check "gateway root key var" "example-gateway-root" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "ROOT_ACCESS_KEY") | .valueFrom.secretKeyRef.name' $gwD)"
  check "gateway root key ref" "example-access-key" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "ROOT_ACCESS_KEY") | .valueFrom.secretKeyRef.key' $gwD)"
  check "gateway root secret var" "example-secret-key" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "ROOT_SECRET_KEY") | .valueFrom.secretKeyRef.key' $gwD)"
  check "sync api key ref" "example-api-key" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "STGUIAPIKEY") | .valueFrom.secretKeyRef.key' $syncD)"
  # The two halves of "named, never carried", read off the bytes. A variable that carries a literal
  # `value` is a credential in git even when the name beside it looks like a reference; a rendered
  # Secret object is this repository having invented one, which it has no way to do.
  check "gateway root key carries no literal value" "null" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "ROOT_ACCESS_KEY") | .value' $gwD)"
  check "sync api key carries no literal value" "null" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "STGUIAPIKEY") | .value' $syncD)"
  # `-L` because the rendered tree is symlinks -- see the note at the namespace count below.
  check "no Secret object is rendered at all" "0" "$(find -L $manifests -name 'Secret-*.yaml' -type f | wc -l)"

  echo "== the gateway's own command line agrees with the port it declares =="
  check "gateway bind arg" ":7070" \
    "$(y '.spec.template.spec.containers[0].args[] | select(. == ":7070")' $gwD)"
  check "gateway admin plane is loopback" "true" \
    "$(y '.spec.template.spec.containers[0].args[] | select(. == "127.0.0.1:7071")' $gwD | grep -q . && echo true || echo false)"

  echo "== probes: what the catalogue said, including a liveness that is deliberately not HTTP =="
  check "share readiness path" "/api/configs" "$(y '.spec.template.spec.containers[0].readinessProbe.httpGet.path' $shareD)"
  check "share cold-start tolerance" "30" "$(y '.spec.template.spec.containers[0].readinessProbe.failureThreshold' $shareD)"
  check "share liveness is TCP" "3000" "$(y '.spec.template.spec.containers[0].livenessProbe.tcpSocket.port' $shareD)"
  check "share liveness is not HTTP" "null" "$(y '.spec.template.spec.containers[0].livenessProbe.httpGet' $shareD)"
  check "gateway liveness slack" "5" "$(y '.spec.template.spec.containers[0].livenessProbe.timeoutSeconds' $gwD)"

  echo "== an object is named by what it is CALLED here, while the declaration is keyed by what it IS =="
  check "gateway object name" "example-gateway-legacy" "$(y '.metadata.name' $gwD)"
  check "gateway selector follows the name" "example-gateway-legacy" \
    "$(y '.spec.selector.matchLabels."app.kubernetes.io/name"' $gwD)"
  check "gateway container follows the name" "example-gateway-legacy" \
    "$(y '.spec.template.spec.containers[0].name' $gwD)"
  check "a workload that renames nothing keeps its key" "example-share" "$(y '.metadata.name' $shareD)"

  echo "== a deployment's own flag lands BEFORE the positional words the command line must end with =="
  # The whole point of splitting the catalogue's arguments in two. One appended list would produce
  # `... posix /data --cors-allow-origin https://example.com`, which is a different command line and
  # not one this gateway accepts -- and nothing about the rendered pod would look wrong.
  gwArgs=$(y '.spec.template.spec.containers[0].args | join(" ")' $gwD)
  check "the catalogue's own flags come first" "--port :7070" "$(echo "$gwArgs" | cut -d' ' -f1,2)"
  check "the positional words come last" "posix /data" "$(echo "$gwArgs" | awk '{print $(NF-1), $NF}')"
  check "the declaration's flag is between them" "--access-log /dev/stdout --cors-allow-origin https://example.com posix /data" \
    "$(echo "$gwArgs" | awk '{ o=""; for (i=NF-5; i<=NF; i++) o = o (o=="" ? "" : " ") $i; print o }')"

  echo "== what the process needs from the KERNEL is the catalogue's, and an unestablished entry renders nothing =="
  check "share drops every capability" "ALL" \
    "$(y '.spec.template.spec.containers[0].securityContext.capabilities.drop[0]' $shareD)"
  check "share cannot gain privileges" "false" \
    "$(y '.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation' $shareD)"
  # NOT the same as `false`, and this is the check that keeps it that way: an application whose
  # privileges nobody has established carries no securityContext at all, so adopting this module
  # does not harden a live container on a guess.
  check "gateway carries no securityContext" "null" \
    "$(y '.spec.template.spec.containers[0].securityContext' $gwD)"
  check "sync carries no securityContext" "null" \
    "$(y '.spec.template.spec.containers[0].securityContext' $syncD)"
  # A read-only root filesystem is deliberately not claimed anywhere, and `false` is not absence:
  # the field must not appear at all.
  check "nothing states a root filesystem it has not proven" "null" \
    "$(y '.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem' $shareD)"

  echo "== how much of one cluster a workload may have is the declaration's, and unset renders nothing =="
  check "gateway cpu request" "50m" "$(y '.spec.template.spec.containers[0].resources.requests.cpu' $gwD)"
  check "gateway memory request" "64Mi" "$(y '.spec.template.spec.containers[0].resources.requests.memory' $gwD)"
  check "gateway memory limit" "512Mi" "$(y '.spec.template.spec.containers[0].resources.limits.memory' $gwD)"
  check "gateway takes no cpu ceiling" "null" "$(y '.spec.template.spec.containers[0].resources.limits.cpu' $gwD)"
  check "a workload that asked for nothing renders no resources" "null" \
    "$(y '.spec.template.spec.containers[0].resources' $shareD)"

  echo "== a variable this deployment adds is still a reference, and still not a wholesale load =="
  check "tenant key secret" "example-gateway-tenant" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "EXAMPLE_TENANT_ACCESS_KEY") | .valueFrom.secretKeyRef.name' $gwD)"
  check "tenant key ref" "example-access-key" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "EXAMPLE_TENANT_ACCESS_KEY") | .valueFrom.secretKeyRef.key' $gwD)"
  check "tenant key carries no literal value" "null" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "EXAMPLE_TENANT_ACCESS_KEY") | .value' $gwD)"
  # Two variables out of ONE Secret: the declaration is written per variable and the pod spec
  # groups per Secret, which is this module's regrouping rather than the declaration's problem.
  check "both tenant variables reached the pod" "2" \
    "$(y '[.spec.template.spec.containers[0].env[] | select(.valueFrom.secretKeyRef.name == "example-gateway-tenant")] | length' $gwD)"
  check "nothing was loaded wholesale" "null" "$(y '.spec.template.spec.containers[0].envFrom' $gwD)"

  echo "== the image is a tag when a version was given and a whole reference when one was =="
  check "share image" "stonith404/pingvin-share:0.0.0" "$(y '.spec.template.spec.containers[0].image' $shareD)"
  check "gateway digest-pinned" "true" \
    "$(y '.spec.template.spec.containers[0].image' $gwD | grep -q '@sha256:' && echo true || echo false)"

  echo "== no address is invented here: every Service is a plain ClusterIP with nothing pinned =="
  for f in $share/Service-example-share.yaml $gw/Service-example-gateway-legacy.yaml $sync/Service-example-sync.yaml; do
    check "$(basename $f) type" "ClusterIP" "$(y '.spec.type' $f)"
    check "$(basename $f) no pinned IP" "null" "$(y '.spec.clusterIP' $f)"
    check "$(basename $f) no nodePort" "null" "$(y '.spec.ports[0].nodePort' $f)"
  done

  # `-L` is load-bearing: the rendered tree is SYMLINKS into the store, so a plain `-type f`
  # matches nothing and returns a confident zero. A count that can only ever be zero is worse than
  # no check, because it passes the moment somebody expects zero.
  echo "== two namespaces, each anchored exactly once =="
  check "namespaces rendered" "2" "$(find -L $manifests -name 'Namespace-*.yaml' -type f | wc -l)"
  check "shared namespace" "example-shares" "$(y '.metadata.name' $share/Namespace-example-shares.yaml)"
  check "sync namespace"   "example-sync"   "$(y '.metadata.name' $sync/Namespace-example-sync.yaml)"

  if [ "$fail" -ne 0 ]; then
    echo "rendered output does not match the catalogue's promises" >&2
    exit 1
  fi
  echo "nixshare: the rendered tree matches every promise asserted here"
  touch $out
''
