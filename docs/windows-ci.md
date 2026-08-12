# Windows CI — how the fleet is wired

## Shape

Nix does not run on Windows. The only Nix on a Windows box is inside WSL2, which
is Linux and produces ELF. So:

```
ubuntu-latest                                windows-latest
  nix build .#packages.x86_64-windows.*
  stage/                                     download artifact
  static gates (format, imports, .lgx)  ──▶  run the SAME smoke script
  upload artifact                            ← the only real Windows coverage
        │
        └─▶ ubuntu-latest: same script under wine (fast red, not a substitute)
```

`logos-libp2p-module`'s existing `windows-wsl` job is the counter-example: it
burns a windows-latest runner, a WSL Ubuntu install and a cold Nix bootstrap on
every run to build and test `x86_64-linux` binaries. Delete or convert it.

## What a repo adds

One file, `.github/workflows/windows.yml`, from `windows.yml.template`. Nothing
else — no Nix pinning, no cache config, no gate scripts.

```yaml
jobs:
  windows:
    uses: logos-co/logos-nix/.github/workflows/windows-ci.yml@v1
    secrets: inherit
    with:
      targets: lgx
      smoke: |
        run bin/lgx.exe --help | grep -qi usage
```

## What a repo with no Windows target does

Nothing. Do not add the file. `windows-ci.yml` fails loudly on a repo with no
`packages.x86_64-windows` rather than passing with nothing to build — 23 of the
45 repos that have Linux+macOS CI are in this bucket, so that is the most likely
way this design gets misapplied.

For a **module** repo the port is usually a `logos-module-builder` bump and no
source change at all: `lib/common.nix` in module-builder adds `x86_64-windows`
to `systems` and routes it through `logos-nix.lib.mkWindowsPkgs`. Measured — with
module-builder overridden to master, `logos-accounts-module` goes from
"attribute missing" to 17 Windows attributes, `logos-delivery-module` to 20.
It does **not** work for a module repo that rebuilds `packages` over its own
hardcoded `systems` list (logos-storage-module, logos-chat-module,
logos-test-modules, the Rust/Nim ones) — those need real work.

`windows-fleet-audit.yml` runs weekly and fails when a repo gains a Windows
target and nobody added the caller.

## Cost

Measured, `x86_64-linux` under emulation, 6 cores, `logos-package`'s `lgx`:

| | wall | note |
|---|---|---|
| cold, empty store | **18m52s** | dominated by mingw `icu4c`; 4 derivations |
| unchanged PR | **1.2s** build + ~2 min job overhead | |
| source-change PR | **31s** build | rebuilds only this repo's own derivation |

The mingw **toolchain** substitutes from `cache.nixos.org`. The mingw **Qt**
stack does not, in either cache — `qtbase`, `qtdeclarative`, `qtsvg`,
`qtremoteobjects`, `icu4c`, `boost` were all probed 404 on both. Nobody upstream
will ever fill it: nixpkgs' Hydra does not build cross Qt.

**So priming is a prerequisite, not an optimisation.** Run
`windows-cache-prime.yml` to green before enabling any Qt-dependent caller. Until
then, `windows-ci.yml` refuses to start a build over `cold-derivation-budget`
(default 30 derivations) and tells you to prime — a 60-second red instead of a
four-hour one.
