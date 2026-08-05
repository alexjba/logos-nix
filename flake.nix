{
  description = "Logos Nix — shared Nix infrastructure for all Logos projects";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      # Build platforms from which the Windows target may be produced.
      #
      # The overlay evaluates from Darwin too, but builds belong on Linux:
      # wine (for smoke tests) does not exist for aarch64-darwin at all, and
      # upstream nixpkgs only exercises mingw cross from x86_64-linux via
      # release-cross.nix.
      windowsBuildSystems = [ "x86_64-linux" ];

      # x86_64-w64-mingw32 with UCRT rather than the legacy MSVCRT. UCRT is
      # MSYS2's default, has correct C99 printf and UTF-8 locale behaviour, and
      # is what Microsoft ships on Windows 10+. (`mingwW64` in
      # lib/systems/examples.nix is the MSVCRT spelling, and upstream carries a
      # removal TODO above it.)
      windowsCrossSystem = {
        config = "x86_64-w64-mingw32";
        libc = "ucrt";
      };

      windowsCrossOverlay = import ./nix/windows/cross-overlay.nix;
      windowsNativeOverlay = import ./nix/windows/native-overlay.nix;

      # Package set targeting Windows, built FROM `buildSystem`.
      #
      # This is a SEPARATE `import` of the SAME pinned nixpkgs — not a second
      # nixpkgs pin. The overlays never reach a repo's ordinary `pkgs`, so
      # native Linux/macOS closures are unaffected by Windows support existing.
      mkWindowsPkgs =
        { buildSystem
        , libc ? windowsCrossSystem.libc
        }: import nixpkgs {
          localSystem = buildSystem;
          crossSystem = windowsCrossSystem // { inherit libc; };
          overlays = [ windowsNativeOverlay ]; # BUILD-side fixes
          crossOverlays = [ windowsCrossOverlay ]; # HOST-side fixes
        };

      forAllSystems = f:
        nixpkgs.lib.genAttrs supportedSystems (system:
          f {
            inherit system;
            pkgs = import nixpkgs { inherit system; };
          });

      # forAllSystems, plus the Windows target keyed under the pseudo-system
      # "x86_64-windows".
      #
      # Keying it as a system rather than as a package-name suffix is
      # deliberate: consumer flakes are full of `dep.packages.${system}.foo`
      # interpolations (49 of them across logos-logoscore-cli and
      # logos-basecamp alone) and every one keeps working unchanged.
      #
      # A cross derivation's `system` attribute is its BUILD platform, so
      # `packages.x86_64-windows.*` evaluates anywhere but realises on
      # x86_64-linux.
      forAllTargets = f:
        nixpkgs.lib.genAttrs (supportedSystems ++ [ "x86_64-windows" ]) (system:
          if system == "x86_64-windows" then
            f {
              inherit system;
              pkgs = mkWindowsPkgs { buildSystem = "x86_64-linux"; };
            }
          else
            f {
              inherit system;
              pkgs = import nixpkgs { inherit system; };
            });
    in
    {
      lib = {
        inherit
          supportedSystems
          forAllSystems
          forAllTargets
          mkWindowsPkgs
          windowsBuildSystems
          windowsCrossSystem
          ;

        overlays = {
          windows = windowsCrossOverlay;
          windowsNative = windowsNativeOverlay;
        };
      };

      # nix build .#legacyPackages.x86_64-linux.pkgsWindows.qt6.qtbase
      legacyPackages = nixpkgs.lib.genAttrs supportedSystems (system:
        (import nixpkgs { inherit system; }) // {
          pkgsWindows = mkWindowsPkgs { buildSystem = system; };
        });

      # Drift guard for the Windows overlay.
      #
      # The overlay's dangerous failure mode is SILENT: an input filter that
      # matches nothing, or an `overrideAttrs` that drops `meta.platforms`,
      # leaves a package that still evaluates while no longer being fixed.
      # These assertions encode the properties the overlay exists to provide,
      # so a Qt bump that invalidates one fails here in seconds rather than
      # hours into a cross build.
      checks = forAllSystems ({ system, pkgs, ... }:
        let
          inherit (pkgs) lib;
          w = mkWindowsPkgs { buildSystem = system; };

          # The four Qt modules Logos actually consumes.
          requiredQtModules = [ "qtbase" "qtdeclarative" "qtremoteobjects" "qtsvg" ];

          hasFlagPrefix = drv: prefix:
            builtins.any (f: lib.hasPrefix prefix f) (drv.cmakeFlags or [ ]);

          qtbaseInputNames =
            map (p: p.pname or p.name or "")
              (builtins.filter lib.isDerivation
                ((w.qt6.qtbase.buildInputs or [ ])
                  ++ (w.qt6.qtbase.propagatedBuildInputs or [ ])));

          excludes = n: !(builtins.any (x: lib.hasPrefix n x) qtbaseInputNames);

          assertions = [
            # Every required module resolves for the Windows host...
            {
              name = "all four Qt modules resolve";
              ok = builtins.all (m: builtins.isString w.qt6.${m}.drvPath) requiredQtModules;
            }
            # ...and still says so in its meta. Catches the qtModule trap:
            # qtModule.nix attaches meta with `//` AFTER mkDerivation returns,
            # so a naive overrideAttrs silently drops meta.platforms.
            {
              name = "Qt modules still declare x86_64-windows";
              ok = builtins.all
                (m: builtins.elem "x86_64-windows" (w.qt6.${m}.meta.platforms or [ ]))
                requiredQtModules;
            }
            # qtbase hardcodes -DQT_FEATURE_libproxy=ON while the overlay
            # filters libproxy out of its inputs, so this override is
            # load-bearing, not cosmetic.
            {
              name = "qtbase disables libproxy";
              ok = hasFlagPrefix w.qt6.qtbase "-DQT_FEATURE_libproxy=OFF";
            }
            {
              name = "qtbase disables vulkan";
              ok = hasFlagPrefix w.qt6.qtbase "-DQT_FEATURE_vulkan=OFF";
            }
            # repc is a build-platform tool in its own store path, which
            # -DQT_HOST_PATH=<qtbase> cannot reach.
            {
              name = "qtremoteobjects points at build-platform repc";
              ok = hasFlagPrefix w.qt6.qtremoteobjects "-DQt6RemoteObjectsTools_DIR=";
            }
            # A filter that silently matches nothing is the drift mode we fear
            # most, so assert on what it must have removed.
            { name = "qtbase drops libglvnd"; ok = excludes "libglvnd"; }
            { name = "qtbase drops libproxy"; ok = excludes "libproxy"; }
            { name = "qtbase drops vulkan"; ok = excludes "vulkan"; }
            # glib's target-python redirect held, keeping the mingw CPython
            # port out of the closure entirely.
            { name = "no target python3 in qtbase closure"; ok = excludes "python3"; }
            # cli11 is a direct logosctl dependency and is platforms.unix
            # upstream.
            { name = "cli11 available for Windows"; ok = builtins.isString w.cli11.drvPath; }
          ];

          gate = lib.foldl'
            (acc: a: acc && (lib.assertMsg a.ok "windows overlay drift: ${a.name}"))
            true
            assertions;
        in
        {
          windows-overlay = assert gate;
            pkgs.runCommand "windows-overlay-eval-gate" { } "touch $out";
        });

      devShells = forAllSystems ({ pkgs, ... }: {
        default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            cmake
            ninja
            pkg-config
            qt6.wrapQtAppsNoGuiHook
          ];

          buildInputs = with pkgs; [
            qt6.qtbase
            qt6.qtremoteobjects
          ];
        };
      });
    };
}
