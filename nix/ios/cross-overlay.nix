# iOS (arm64-apple-ios) cross overlay — HOST-side, applied via `crossOverlays`.
# Every compile goes through the version-gated Xcode wrapper in `__noChroot`
# derivations; nixpkgs' own iOS toolchain is not used.
final: prev:

let
  lib = final.lib;
  hostPlatform = final.stdenv.hostPlatform;
  isCross = !final.stdenv.buildPlatform.canExecute hostPlatform;

  hostQt = final.pkgsBuildBuild.qt6;

  appleSdk = if hostPlatform.darwinPlatform == "ios-simulator" then "iphonesimulator" else "iphoneos";
  arch = hostPlatform.darwinArch;

  # The four modules Logos consumes; order matters for the prefix-path lists.
  qtModules = [
    "qtbase"
    "qtdeclarative"
    "qtshadertools"
    "qtsvg"
  ];
  prefixPath = scope: lib.concatStringsSep ";" (map (m: "${scope.${m}}") qtModules);
in
{
  xcodeWrapper = final.pkgsBuildBuild.callPackage ./xcode-wrapper.nix {
    inherit (hostPlatform) xcodeBuild;
    xcodeVersion = hostPlatform.xcodeVer;
  };

  # Same contract as the Windows overlay: `pkgs.logosQtCrossCmakeFlags or []`
  # is appendable -D flags only, empty natively. The toolchain file (which
  # carries CMAKE_SYSTEM_NAME=iOS and the SDK/arch qtbase was built with) is
  # a separate attribute because a consumer may already pass its own.
  logosQtCrossToolchainFile =
    lib.optionalString isCross "${final.qt6.qtbase}/lib/cmake/Qt6/qt.toolchain.cmake";

  logosQtCrossCmakeFlags = lib.optionals isCross [
    "-DCMAKE_OSX_SYSROOT=${appleSdk}"
    "-DCMAKE_OSX_ARCHITECTURES=${arch}"
    "-DQT_HOST_PATH=${hostQt.qtbase}"
    "-DQT_ADDITIONAL_HOST_PACKAGES_PREFIX_PATH=${prefixPath hostQt}"
    "-DQT_ADDITIONAL_PACKAGES_PREFIX_PATH=${prefixPath final.qt6}"
  ];

  # How everything iOS compiles; qt-module.nix and mkIosCmakeStage share it.
  xcodeClang = final.callPackage ./xcode-clang.nix {
    inherit (final) xcodeWrapper;
    inherit appleSdk;
    inherit (final.pkgsBuildBuild) cmake ninja;
  };

  # An app's static-archive stage: `pkgs.mkIosCmakeStage { pname; version;
  # src; sourceDir ? "."; cmakeFlags ? []; buildInputs ? []; ... }`.
  mkIosCmakeStage = final.callPackage ./cmake-stage.nix {
    inherit (final) xcodeClang logosQtCrossToolchainFile logosQtCrossCmakeFlags;
  };

  qt6 = prev.qt6.overrideScope (
    qfinal: qprev:
    let
      mkQtModule = final.callPackage ./qt-module.nix {
        inherit (final) xcodeClang;
        inherit hostQt appleSdk arch;
        inherit (qprev) srcs;
      };
    in
    {
      qtbase = mkQtModule { pname = "qtbase"; };

      qtshadertools = mkQtModule {
        pname = "qtshadertools";
        qtDeps = [ qfinal.qtbase ];
        cmakeFlags = [
          "-DQt6ShaderToolsTools_DIR=${hostQt.qtshadertools}/lib/cmake/Qt6ShaderToolsTools"
        ];
      };

      qtsvg = mkQtModule {
        pname = "qtsvg";
        qtDeps = [ qfinal.qtbase ];
      };

      qtdeclarative = mkQtModule {
        pname = "qtdeclarative";
        qtDeps = [
          qfinal.qtbase
          qfinal.qtshadertools
          qfinal.qtsvg
        ];
        nativeBuildInputs = [ final.pkgsBuildBuild.python3 ];
        cmakeFlags = [
          "-DPython_EXECUTABLE=${lib.getExe final.pkgsBuildBuild.python3}"
          "-DQt6QmlTools_DIR=${hostQt.qtdeclarative}/lib/cmake/Qt6QmlTools"
          "-DQt6QuickTools_DIR=${hostQt.qtdeclarative}/lib/cmake/Qt6QuickTools"
          # Qt6ShaderToolsTools (host qsb), not Qt6ShaderTools (target config):
          # without it Qt Quick is silently not built. Same trap as Windows.
          "-DQt6ShaderToolsTools_DIR=${hostQt.qtshadertools}/lib/cmake/Qt6ShaderToolsTools"
        ];
      };
    }
  );
}
