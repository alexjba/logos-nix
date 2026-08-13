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
  run bin/lgx.exe --help         # refused by run's pre-flight; stage/bin does not exist
```

This is not a hypothetical. The first draft of the `logos-package` caller said
`run bin/lgx.exe --help`, and staging that repo's real output and running it on
a Windows 11 box reproduced `run: line 2: .../stage/bin/lgx.exe: No such file or
directory`, exit 127 — on **both** legs, for a build that was otherwise perfect.

That bare 127 is what the `run` wrapper exists to replace. Re-measured on a
Windows 11 box against a real staged tree, a wrong path now produces:

```
::error::run: 'bin/lgpm.exe' does not exist (cwd: .../tree).
::error::Smoke paths are relative to the staged tree ROOT, and the root holds
::error::one directory PER TARGET -- so a path starts with the target name:
::error::staged targets here: lgpm
```

and exit **1**, not 127 — the distinction matters, because 127 is also what a
missing DLL looks like from an MSYS parent.

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
* treats `53`/`127` **with empty stdout** as STATUS_DLL_NOT_FOUND and says so,
  listing what actually shipped beside the binary — but only when stderr
  corroborates it, i.e. stderr is empty (the wine shape) or names a DLL (the
  MSYS shape). A program that exits 53 or 127 and explains itself on stderr
  gets its own message and its own exit code, because eight confident lines
  about a missing DLL aimed at an unrelated failure is worse than silence.
  Measured on Windows 11 with a real PE exiting 53 with only a stderr line: the
  pre-corroboration version answered with the DLL story **and** listed all of
  `C:\Windows\System32` — 18,941 lines — as "shipped beside it";
* lists only `53` and `127`. Bash masks a child's status to 0–255, so the raw
  `3221225781` / `-1073741515` spellings of 0xC0000135 can never appear in `$?`;
  they were dead branches;
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

The comparison also has a **floor**, because two files that agree on being empty
agree about nothing: an empty tree carrying an empty manifest used to print
"artifact round trip verified: 0 PEs" and exit 0, and the smoke script then ran
against nothing. An artifact must carry at least one PE, or at least one `.lgx`
(the one shape whose PEs legitimately live inside an archive).

## The gates' reader is pinned, and proved

The import-closure gate is the one that decides whether a tree is complete, and
it is worth exactly what its `objdump` is worth. It comes from **logos-nix's own
flake.lock** — `path:$GITHUB_ACTION_PATH/../../..#legacyPackages.x86_64-linux.pkgsWindows.buildPackages.binutils`,
the same pin that produced the PEs — not from the runner's flake registry. Those
are different binaries: measured from one machine a minute apart,
`nixpkgs#pkgsCross.mingwW64.buildPackages.binutils` resolved to `2ygvxdjd…`
while the pin resolved to `a54mx5f1…`. The pinned path is in `cache.nixos.org`,
so this costs a substitution, not a build.

Before it is trusted, the action asserts `objdump --info` lists `pei-x86-64`,
and `import_closure.py` requires each file to report `file format pei-x86-64`.
Neither check is decoration: a reader that cannot parse a PE reports zero
imports, and zero imports is also what a perfectly bundled tree reports.

`$OBJDUMP` is exported to `$GITHUB_ENV`, so a caller's `extra-gates` script uses
that same verified binary instead of resolving a second one.

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

### The audit has three outcomes, and "unknown" is a failure

Every listed repo lands in exactly one bucket, and the job asserts the buckets
add up to the repos listed. Alongside *covered* and *drift* there is **NOT
AUDITED**: a repo whose flake fails to evaluate, whose eval times out, or whose
contents probe returns anything other than 200 or 404. Those fail the job.

This is not defensive padding. The first version ran `set -uo pipefail` without
`-e`, so a failed `gh api` left an empty repo list, the loop body never ran, and
the job exited **0** having audited **nothing** — reproduced with a `gh` that
returns HTTP 403: `candidate repos: 0`, green. The same version filed every
non-zero `nix eval` under "no Windows target", so a repo whose flake was broken
and one whose eval hung were both reported as out of scope, and a repo whose
probe was rate-limited mid-loop vanished from all three buckets while the job
stayed green. A job that passes by skipping is worse than no job.

There is also a floor on the listing itself: fewer than 20 repos is treated as a
degraded API call, not a smaller org.

## Versioning: what `@v1` covers

`windows-ci.yml` is a **cross-repo** reusable workflow, so it cannot reference
its sibling actions with a relative path. A `uses: ./.github/actions/...` inside
a called reusable workflow is resolved in the **caller's** workspace, not in
logos-nix, and fails. The absolute `logos-co/logos-nix/.github/actions/<name>@<ref>`
form is therefore mandatory, and the ref is a real decision rather than a
formality.

The rule: **`v1` is one train.** The workflow and all three actions
(`nix-setup`, `windows-gates`, `windows-smoke`) are tagged from the same commit
and move together. Every `uses:` **inside `windows-ci.yml`** says `@v1` — the
same string the callers use.

That rule is about the *reusable workflow* only, and the distinction is easy to
"fix" in the wrong direction. logos-nix's own workflows —
`windows-cache-prime.yml` (3 sites) and `windows-fleet-audit.yml` (1) — run in
**this** repo's checkout, where `uses: ./.github/actions/nix-setup` resolves
correctly and pins nothing to a tag that may not exist yet. They are right as
they are. Only a workflow that is `uses:`-ed *by another repo* has to spell its
siblings absolutely, because that one is evaluated in the caller's workspace.

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
