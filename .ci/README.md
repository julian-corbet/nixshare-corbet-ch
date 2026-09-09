Checks are selected through `.ci/ccid.toml` and run by the pinned shared ccid runner on a trusted worker.

The default selection is `eval,native`. Native Linux success does not certify a foreign architecture, a separately selected image or hardware gate, or publication. Use `list` to inspect available native Nix checks, and select existing results or affected checks before scheduling more work.

Additional coverage limits:

- Native ARM Linux execution exists in Actions; x86 Crow cannot replace that evidence. Keep native gate explicit.

Hosted Actions keeps native ARM automatic and preserves the full manual matrix; Crow runs the portable x86 checks.
