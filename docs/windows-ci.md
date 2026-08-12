# Windows CI — how the fleet is wired

## Shape

Nix does not run on Windows. The only Nix on a Windows box is inside WSL2, which
is Linux and produces ELF. So:

```
ubuntu-latest                                windows-latest
  nix build .#packages.x86_64-windows.*
  stage/                                     download artifact
  static gates (format, imports, .lgx)       re-count the PE manifest
  write pe-manifest.txt                 ──▶  run the SAME smoke script
  upload artifact                            ← the only real Windows coverage
        │
        └─▶ ubuntu-latest: same script under wine (fast red, not a substitute)
```

`logos-libp2p-module`'s existing `windows-wsl` job is the counter-example: it
burns a windows-latest runner, a WSL Ubuntu install and a cold Nix bootstrap on
every run to build and test `x86_64-linux` binaries. Delete or convert it.

## The staged tree layout is a contract

`stage/` holds **one directory per target and nothing else**. A single-target
repo whose target is `lgx` gets:

```
stage/lgx/bin/lgx.exe
stage/lgx/bin/*.dll
stage/pe-manifest.txt
```

There is no `stage/bin`. Smoke scripts run from `stage/`, so every path they
name **starts with the target name**:

```yaml
smoke: |
  run lgx/bin/lgx.exe --help     # correct
  run bin/lgx.exe --help         # exits 127; stage/bin does not exist
```

This is not a hypothetical. The first draft of the `logos-package` caller said
`run bin/lgx.exe --help`, and staging that repo's real output and running it on
a Windows 11 box reproduced `run: line 2: .../stage/bin/lgx.exe: No such file or
directory`, exit 127 — on **both** legs, for a build that was otherwise perfect.

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
        run lgx/bin/lgx.exe --help | grep -qi usage
```

## `run`, and the three silent failures it names

Every PE is launched through a `run` wrapper on `PATH` — wine on the Linux leg,
a direct exec on the Windows leg, so one script serves both. It exists because
**every way a staged Windows binary fails to start is silent**, and two of them
are indistinguishable by exit code. Measured against `lgx.exe` with exactly one
DLL removed from an otherwise-working tree:

| launcher | intact | missing DLL | missing path |
|---|---|---|---|
| Windows, non-bash parent | `0`, output | **`-1073741515`** (0xC0000135), stdout **and** stderr empty | n/a |
| Windows, Git-Bash/MSYS parent (the CI leg) | `0`, output | `127`, stdout empty, stderr names an **arbitrary** dependency — `libgcc_s_seh-1.dll` every time, whichever DLL was actually removed | `127`, "No such file or directory" |
| wine 11.0 on Linux | `0`, output | `53` (`0xC0000135 & 0xFF`), stdout **and** stderr empty | `53` + "wine: failed to open" |

So `run`:

* checks the PE exists **before** launching it, which is the only thing that
  separates "wrong path" from "missing DLL" on either leg;
* treats `53`/`127`/`0xC0000135` **with empty stdout** as STATUS_DLL_NOT_FOUND
  and says so, listing what actually shipped beside the binary;
* treats **exit 0 with no output at all** as a failure. Silent success is this
  project's dominant defect class; a smoke test that cannot tell "it worked"
  from "it did nothing" is not coverage. Use `run -q` for a command that is
  genuinely silent.

## The artifact round trip is asserted, not assumed

The builder writes `pe-manifest.txt` into the tree root immediately before
upload; each smoke leg re-counts and diffs it. The upload/download hop is the
one link in this chain nobody has ever observed end to end, and a PE that
disappears there would otherwise reappear as an inscrutable launch failure.

The file is deliberately **not** dot-prefixed: `upload-artifact@v4` excludes
hidden files unless `include-hidden-files` is set, so a `.pe-manifest.txt` would
be dropped silently — the exact failure class it exists to detect.

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

## Versioning: what `@v1` covers

`windows-ci.yml` is a **cross-repo** reusable workflow, so it cannot reference
its sibling actions with a relative path. A `uses: ./.github/actions/...` inside
a called reusable workflow is resolved in the **caller's** workspace, not in
logos-nix, and fails. The absolute `logos-co/logos-nix/.github/actions/<name>@<ref>`
form is therefore mandatory, and the ref is a real decision rather than a
formality.

The rule: **`v1` is one train.** The workflow and all three actions
(`nix-setup`, `windows-gates`, `windows-smoke`) are tagged from the same commit
and move together. Every internal `uses:` says `@v1` — the same string the
callers use.

What breaks if the tag moves:

* Moving `v1` to a commit changes the behaviour of every caller at once, with no
  PR anywhere. That is the point of a train, and the cost of it. Only move `v1`
  to a commit where the workflow and the actions are mutually consistent.
* A caller that pins a **SHA** or a **branch** (`windows-ci.yml@abcd123`) still
  gets its actions from `v1`, because the internal refs are absolute. That
  combination silently mixes two commits: an old workflow body calling new
  actions. Callers use the tag. If you must pin a caller to a SHA for a
  bisect, pin the internal refs in that same SHA too, and do not merge it.
* Nothing runs before the tag exists. logos-nix has no tags today; `v1` must be
  created on the merge commit of the Windows-CI branch into `master` — the
  commit that contains `windows-ci.yml` **and** all three action directories —
  before the first caller can be enabled.

## Cost

Measured, `x86_64-linux`, 6 cores, `logos-package`'s `lgx`:

| | wall | note |
|---|---|---|
| cold, empty store | **18m52s** | dominated by mingw `icu4c`; 4 derivations |
| warm store, this repo's derivation only | **~30s** | 1 derivation, 15 MiB staged |
| unchanged PR | **1.2s** build + ~2 min job overhead | |

The mingw **toolchain** substitutes from `cache.nixos.org`. The mingw **Qt**
stack does not, in either cache — `qtbase`, `qtdeclarative`, `qtsvg`,
`qtremoteobjects`, `icu4c`, `boost` were all probed 404 on both. Nobody upstream
will ever fill it: nixpkgs' Hydra does not build cross Qt.

**So priming is a prerequisite, not an optimisation.** Run
`windows-cache-prime.yml` to green before enabling any Qt-dependent caller. Until
then, `windows-ci.yml` refuses to start a build over `cold-derivation-budget`
(default 30 derivations) and tells you to prime — a 60-second red instead of a
four-hour one.
