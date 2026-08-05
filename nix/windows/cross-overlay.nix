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

  # glib pulls a TARGET-platform python3, which is what drags in the broken
  # mingw CPython (and the 28-patch port proposed in NixOS/nixpkgs#476281).
  # `python3Packages` is a callPackage argument, so redirecting it to the
  # build platform removes python3 from the Windows closure entirely.
  glib = prev.glib.override {
    python3Packages = final.buildPackages.python3Packages;
  };

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
