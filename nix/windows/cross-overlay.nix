# Windows (x86_64-w64-mingw32) cross overlay — HOST-side fixes.
#
# Applied via `crossOverlays`, so it only ever touches the Windows target
# package set.  Native Linux/macOS closures are untouched.
#
# See ./native-overlay.nix for the BUILD-side half.
final: prev:

let
  lib = final.lib;
  hostPlatform = final.stdenv.hostPlatform;

  isCross = !final.stdenv.buildPlatform.canExecute hostPlatform;

  # Deliberately dropped even though they ARE available for the Windows host:
  # Logos needs no Vulkan (Qt Quick uses D3D11/OpenGL on Windows), and building
  # the loader + headers for mingw is pure cost.  Paired with
  # `-DQT_FEATURE_vulkan=OFF` below — flip both together if Vulkan is ever
  # wanted, never one alone.
  dropAnyway = [
    "vulkan-loader"
    "vulkan-headers"
  ];

  # `lib.meta.availableOn` expects a package-like attrset; a buildInputs list
  # can also hold setup hooks and `null`.  Guard before asking.
  availableHere =
    p:
    if !(lib.isDerivation p) then
      true
    else
      lib.meta.availableOn hostPlatform p && !(builtins.elem (p.pname or "") dropAnyway);

  widenPlatforms =
    drv:
    drv.overrideAttrs (old: {
      meta = (old.meta or { }) // {
        platforms = (old.meta.platforms or [ ]) ++ lib.platforms.windows;
      };
    });

  # TRAP: qtModule.nix attaches its meta with `//` AFTER mkDerivation returns.
  # A plain `.overrideAttrs` re-runs mkDerivation and therefore drops that
  # outer meta, silently losing `platforms` and re-breaking the package.
  # Always re-attach the original.
  addCmakeFlags =
    extra: drv:
    (drv.overrideAttrs (old: { cmakeFlags = (old.cmakeFlags or [ ]) ++ extra; }))
    // {
      inherit (drv) meta;
    };
in
{
  # Header-only, but upstream declares `platforms = platforms.unix`
  # (pkgs/by-name/cl/cli11/package.nix).  Direct logosctl dependency, and not
  # covered by logos-co/nixpkgs@mingw-integration.
  cli11 = widenPlatforms prev.cli11;

  # glib needs two independent fixes for a Windows host.
  #
  # 1. It pulls a TARGET-platform python3, which is what drags in the broken
  #    mingw CPython (and the 28-patch port proposed in NixOS/nixpkgs#476281).
  #    `python3Packages` is a callPackage argument, so redirecting it to the
  #    build platform removes python3 from the Windows closure entirely.
  #
  # 2. It unconditionally links libsysprof-capture except on FreeBSD:
  #        buildInputs ++ lib.optionals (!hostPlatform.isFreeBSD) [ libsysprof-capture ]
  #        mesonFlags  ++ lib.optionals   hostPlatform.isFreeBSD  [ "-Dsysprof=disabled" ]
  #    sysprof-capture is Linux-only — it wants <sys/mman.h>, <endian.h> and
  #    <sys/syscall.h> — so a Windows target needs exactly the FreeBSD
  #    treatment. This one is invisible to evaluation and only shows up hours
  #    into a build, via qtbase -> harfbuzz -> glib. glib already carries an
  #    `isWindows` guard a few lines below, so upstream simply missed this.
  glib =
    let
      base = prev.glib.override {
        python3Packages = final.buildPackages.python3Packages;
      };
    in
    base.overrideAttrs (old: {
      buildInputs = builtins.filter
        (p: !(lib.isDerivation p && (p.pname or "") == "libsysprof-capture"))
        (old.buildInputs or [ ]);
      mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Dsysprof=disabled" ];
    });

  # nixpkgs' own mingw-boolean.patch is malformed at our pinned rev: it inserts
  # a nested block *after* `#ifndef HAVE_BOOLEAN` without removing or closing
  # that line, so every translation unit including jpeglib.h dies with
  #     src/jmorecfg.h:202: error: unterminated #ifndef
  # qtbase propagates libjpeg, so this stops the Qt build outright.
  #
  # The patch's ADDED block is already correct and self-contained (it is
  # MSYS2's jpeg-typedefs.patch); only the now-redundant outer line is left
  # over. Deleting it post-patch yields exactly the intended MSYS2 form, and
  # avoids re-deriving a patch whose context whitespace we cannot verify here.
  #
  # Fixed upstream in NixOS/nixpkgs#476269, merged 2026-01-09 — AFTER the rev
  # logos-nix pins. Drop this override once the pin moves past it.
  libjpeg_turbo = prev.libjpeg_turbo.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      if ! grep -q '^#ifndef HAVE_BOOLEAN$' src/jmorecfg.h; then
        echo "libjpeg_turbo: expected stray '#ifndef HAVE_BOOLEAN' not found."
        echo "The upstream patch has changed -- re-check whether this override is still needed."
        exit 1
      fi
      sed -i '0,/^#ifndef HAVE_BOOLEAN$/{/^#ifndef HAVE_BOOLEAN$/d}' src/jmorecfg.h
    '';
  });

  # pkg-config bundles an ancient glib (--with-internal-glib) whose
  # gthread-win32.c passes an incompatible pointer to
  # _InterlockedCompareExchangePointer. GCC 14 promoted
  # -Wincompatible-pointer-types from a warning to an ERROR, so the bundled
  # copy no longer compiles for a Windows host.
  #
  # nixpkgs already silences a sibling Windows-only diagnostic here
  #     ++ lib.optionals stdenv.hostPlatform.isWindows [ "-Wno-error=format" ]
  # so this is the same gap as glib's sysprof: partial Windows awareness with
  # one case missed. Demote rather than disable, so genuine new instances in
  # OUR code still fail.
  pkg-config-unwrapped = prev.pkg-config-unwrapped.overrideAttrs (old: {
    env = (old.env or { }) // {
      NIX_CFLAGS_COMPILE =
        (old.env.NIX_CFLAGS_COMPILE or "") + " -Wno-error=incompatible-pointer-types";
    };
  });

  qt6 = prev.qt6.overrideScope (
    qfinal: qprev: {
      # qtModule.nix hardcodes `platforms = platforms.unix`, but merges
      # `args.meta` on top of its own defaults — so injecting meta through
      # ARGS is the intended override channel, and it fixes both the meta
      # mkDerivation checks and the meta the scope exposes.  Wrapping the
      # scope's own qtModule widens every module at once instead of patching
      # ~40 files.
      qtModule =
        args:
        qprev.qtModule (
          args
          // {
            meta = (args.meta or { }) // {
              platforms = lib.platforms.unix ++ lib.platforms.windows;
            };
          }
        );

      # qtbase is NOT built through qtModule and already carries
      # `platforms.unix ++ platforms.windows` at our pin.  What breaks it is
      # that it lists libGL (→ libglvnd, `platforms.unix`) and vulkan
      # unconditionally — NixOS/nixpkgs#401503.
      #
      # FILTERING the computed input lists, rather than patching the source,
      # is what makes this survive qtbase churn across Qt bumps.
      qtbase = qprev.qtbase.overrideAttrs (old: {
        buildInputs = builtins.filter availableHere (old.buildInputs or [ ]);
        propagatedBuildInputs = builtins.filter availableHere (old.propagatedBuildInputs or [ ]);
        # Later -D flags win on the cmake command line, so appending is enough.
        cmakeFlags = (old.cmakeFlags or [ ]) ++ [
          "-DQT_FEATURE_vulkan=OFF"
          "-DQT_FEATURE_libproxy=OFF"
        ];
      });

      # repc / qmltyperegistrar / qsb are BUILD-platform tools living in their
      # own store paths, which `-DQT_HOST_PATH=<qtbase>` cannot reach.  These
      # are the only Qt changes Logos genuinely cannot do without.
      qtremoteobjects = addCmakeFlags (
        lib.optionals isCross [
          "-DQt6RemoteObjectsTools_DIR=${final.pkgsBuildBuild.qt6.qtremoteobjects}/lib/cmake/Qt6RemoteObjectsTools"
        ]
      ) qprev.qtremoteobjects;

      qtdeclarative = addCmakeFlags (
        lib.optionals isCross [
          "-DQt6QmlTools_DIR=${final.pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QmlTools"
          "-DQt6QuickTools_DIR=${final.pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QuickTools"
        ]
      ) qprev.qtdeclarative;
    }
  );
}
