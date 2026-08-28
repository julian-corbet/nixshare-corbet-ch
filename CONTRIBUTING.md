# Contributing to nixshare

nixshare's `protocol` schema is closed by design (`"nfs" | "cifs"` — see
README.md's design note on why these are two providers under one schema
rather than one table with a discriminator), so this is a much thinner
document than a project with an open provider registry — there's no
plugin ecosystem to onboard. It's still worth writing down what "a
provider" means here, for anyone touching `modules/providers/`. FS-Cache
is an NFS-client adjunct rather than a third share protocol: its shared
policy schema lives in `modules/providers/fscache.nix`, while each platform
adapter owns the native daemon lifecycle.

## Ground rules

- **FOSS-clean core.** This repo carries no real peer name, real export
  path, real hostname, or any other site-specific fact — not even in a
  comment or a test fixture. Every example uses an obviously-fake
  placeholder (`storage-host`, `example-share`, `/export/example`, TEST-NET
  addresses). Real values belong only in whatever private configuration
  imports this flake.
- **Core stays protocol-blind.** `modules/core.nix` must never grow
  `if protocol == "nfs"` branches of its own — that's what
  `modules/providers/*.nix` are for. Core owns the schema, the provider
  registry, and the watchdog; nothing else.
- **The watchdog stays mount-shape-blind.** `pkgs/nixshare-watchdog.nix`
  operates purely on `(mountpoint, timeout)` pairs read from JSON — it
  must never need to know whether a given share is NFS or CIFS. A change
  that would require the watchdog to branch on protocol is a sign the
  watchdog is the wrong place for it.
- **Commit style.** Imperative subject line, a body that says *why* when
  the *why* isn't obvious from the diff. No AI attribution lines.

## What a provider module actually does

A provider (`modules/providers/nfs.nix`, `modules/providers/cifs.nix`) is
a NixOS/system-manager module that, in its `config` block:

1. Filters `config.nixshare.shares` down to the entries matching
   its own `protocol` value.
2. Sets `nixshare.providers.<protocol>.enable = true` — this is
   what turns core's assertion ("this share's protocol has no provider
   imported") from a hard error into a pass; see `modules/core.nix`'s
   `providerEnabled` helper.
3. Builds one `systemd.mounts` entry and one `systemd.automounts` entry
   per matching share, interpreting that share's freeform `cacheSettings`
   (documented per-provider, not in core — see each provider's own
   header comment for its recognized keys and defaults) into an actual
   mount option string, and constructing the protocol's own `what =`
   syntax (`peer:remotePath` for NFS, `//peer/remotePath` for CIFS) from
   the share's generic `peer`/`remotePath` fields.

That's the entire contract. A third protocol (say, a future `sshfs`
provider) would follow the same three steps.

## FS-Cache provider boundary

`fscache-provider` does not create mounts. It supplies the local daemon and
kernel capability required by NFS shares that set `cacheSettings.fsc =
"true"`, plus the AUR package intent for a system-manager host's own
reconciler. The system-manager core marks those selected packages explicit
after that host-owned transaction; it must never install, remove, or replace a
host's package reconciler. Keep storage policy — a Btrfs subvolume, quota,
dedicated mount, or any other host-specific backing-store guarantee — in the
consuming host. The public module may require an absolute cache directory and
validate daemon watermarks, but must not assume a particular filesystem or
layout.

## Contributor agreement

By submitting a contribution, you agree to the
[Individual Contributor License Agreement](https://github.com/corbet-labs/.github/blob/cla-v1.0/CLA.md).
Include this exact affirmation in your pull request description:

<!-- markdownlint-disable MD034 -->

<!-- prettier-ignore -->
> I have read and agree to version 1.0 of the Individual Contributor License Agreement at https://github.com/corbet-labs/.github/blob/cla-v1.0/CLA.md.

<!-- markdownlint-enable MD034 -->

## License

MIT — same as the rest of the repo.
