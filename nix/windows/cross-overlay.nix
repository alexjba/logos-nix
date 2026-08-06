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
  # CMake flags every Qt-consuming Logos repo needs when cross-compiling.
  #
  # Qt splits each module's TOOLS into a separate package -- e.g.
  #     Qt6RemoteObjectsDependencies.cmake:
  #     set(__qt_RemoteObjects_tool_deps "Qt6RemoteObjectsTools;<ver>")
  # -- and those tools (repc, qmltyperegistrar, qsb, moc) must RUN on the build
  # machine, so under cross they live in the build-platform Qt, not the mingw
  # one. Without these flags find_package(Qt6 COMPONENTS RemoteObjects) fails
  # with a thoroughly misleading message:
  #     Expected Config file at <qtbase>/lib/cmake/Qt6RemoteObjects ... does
  #     NOT exist
  # The TARGET config is found fine; it is the HOST tool package that is not.
  #
  # Exposed on the package set (rather than as a logos-nix lib function) so a
  # consumer can write `pkgs.logosQtCrossCmakeFlags or []` and have it degrade
  # to nothing on a native build without threading logos-nix through.
  logosQtCrossCmakeFlags = lib.optionals isCross (
    [ "-DQT_HOST_PATH=${final.pkgsBuildBuild.qt6.qtbase}" ]
    ++ [
      ("-DQT_ADDITIONAL_HOST_PACKAGES_PREFIX_PATH="
        + lib.concatStringsSep ";" (
            map (m: "${final.pkgsBuildBuild.qt6.${m}}") [
              "qtbase"
              "qtremoteobjects"
              "qtdeclarative"
              "qtshadertools"
              "qtsvg"
            ]))
    ]
  );

  # Header-only, but upstream declares `platforms = platforms.unix`
  # (pkgs/by-name/cl/cli11/package.nix).  Direct logosctl dependency, and not
  # covered by logos-co/nixpkgs@mingw-integration.
  cli11 = widenPlatforms prev.cli11;

  # stduuid is header-only, so nothing of it should be COMPILED at all -- but
  # its CMakeLists defaults UUID_BUILD_TESTS to UUID_MAIN_PROJECT, which is ON
  # whenever it is the top-level project, i.e. always in nixpkgs. The test
  # target then does
  #     if (WIN32) ... /EHc /Zc:hiddenFriend
  # treating WIN32 as a synonym for MSVC, and mingw's g++ reads those as input
  # FILENAMES:
  #     x86_64-w64-mingw32-g++: error: /EHc: linker input file not found
  #
  # nixpkgs passes -DBUILD_TESTING=OFF, which stduuid does not consult (CMake
  # even reports it among the "manually-specified variables ... not used").
  # UUID_BUILD_TESTS is the switch that exists. Direct logosctl dependency,
  # via the instance UUID the daemon generates at boot.
  stduuid = prev.stduuid.overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [ (lib.cmakeBool "UUID_BUILD_TESTS" false) ];
  });

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

  # sqlite configures with
  #     (if hostPlatform.isStatic then "--disable-tcl"
  #      else "--with-tcl=${lib.getLib tcl}/lib")
  # so any non-static host pulls TARGET-platform tcl -- and tcl has no mingw
  # port: its build wants tclWinPort.h, which only the win/ source tree
  # provides. `isStatic` is being used as a proxy for "tcl is unavailable",
  # which does not generalise to cross targets.
  #
  # Qt uses libsqlite3 only (QT_FEATURE_system_sqlite), never the TCL bindings,
  # so dropping them costs us nothing. Reached via qtbase -> sqlite -> tcl.
  sqlite = prev.sqlite.overrideAttrs (old: {
    configureFlags =
      (builtins.filter (f: !(lib.hasPrefix "--with-tcl" f)) (old.configureFlags or [ ]))
      ++ [ "--disable-tcl" ];
  });

  # libwebp's CLI tools (img2webp, gif2webp, ...) fail to link on mingw with
  # undefined WebPMux*/WebPAnimEncoder* references. Only the LIBRARY is ever
  # consumed here -- the tools are not installed and nothing in the Qt closure
  # invokes them -- so switch them off rather than chase the link.
  #
  # Ported from logos-co/nixpkgs@mingw-integration, which carries the same fix
  # upstream-style (NixOS/nixpkgs#476343). Later -D flags win on the cmake
  # command line, so appending is enough to override the ON values computed
  # from pngSupport/gifSupport above.
  libwebp = prev.libwebp.overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [
      (lib.cmakeBool "WEBP_BUILD_CWEBP" false)
      (lib.cmakeBool "WEBP_BUILD_DWEBP" false)
      (lib.cmakeBool "WEBP_BUILD_GIF2WEBP" false)
      (lib.cmakeBool "WEBP_BUILD_IMG2WEBP" false)
      (lib.cmakeBool "WEBP_BUILD_VWEBP" false)
      (lib.cmakeBool "WEBP_BUILD_WEBPINFO" false)
      (lib.cmakeBool "WEBP_BUILD_WEBPMUX" false)
    ];
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
