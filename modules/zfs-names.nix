# modules/zfs-names.nix — the one definition of "a ZFS dataset name this repo is willing to inline
# into a root shell script".
#
# NOT a NixOS module: a plain function, imported by both ZFS-backed share providers
# (providers/nfs-server.nix, providers/cifs-server.nix) into their own `let`. It declares no
# options and reads no `config`, so importing it costs a consumer nothing.
#
# WHY IT IS SHARED RATHER THAN COPIED. Both providers build a shell command around a dataset name
# supplied by the operator, and both therefore need the same answer to the same question. When the
# predicate lived in one provider only, the two drifted immediately: nfs rejected a hostile name at
# eval time while cifs accepted it, so the identical declaration was safe in one share type and not
# the other, for no reason a reader could discover. A second copy would have drifted again the first
# time someone widened one of them.
#
# WHY A CONSTRAINT AT ALL, given both providers already escape. Escaping is a defence you have to
# remember at every future interpolation; a constraint on the value is one you cannot forget. That
# is not hypothetical here — the escaping in nfs-server.nix was absent once and the rendered script
# really did execute `touch` as root from a dataset name, and the cifs escaping was demonstrably
# unguarded: reverting it left every check in this repo green. Two layers, deliberately.
#
# WHY THIS CHARACTER CLASS. ZFS itself permits considerably more, including spaces — this is
# narrower than ZFS on purpose. It covers every name a pool actually needs (pool/dataset paths,
# snapshots, the `:` of a user property namespace) and excludes the shell metacharacters that made
# the original defect possible. A name outside it is refused here rather than risked downstream.
{ lib }:
rec {
  # The permitted class, exposed so an assertion message can quote the same string the check uses
  # instead of restating it and going stale.
  safeTreeNamePattern = "[A-Za-z0-9_.:/-]+";

  safeZfsTreeName = tree: builtins.match safeTreeNamePattern tree != null;

  # The shared half of both providers' assertion text. The caller supplies the option path, because
  # naming the exact option the operator has to go and fix is the whole value of the message.
  unsafeTreeNameMessage = { optionPath, tree, unit }: ''
    ${optionPath} is not a safe ZFS dataset name: "${tree}".

    It must match ${safeTreeNamePattern}. ZFS itself permits other characters (including spaces),
    but this module inlines the name into a root shell script (${unit}), so anything outside that
    class is refused at build time rather than risked at runtime.
  '';
}
