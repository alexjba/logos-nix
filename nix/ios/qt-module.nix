# One Qt module for iOS as static frameworks, on Xcode's own toolchain
# (xcode-clang.nix says why not nix's cc-wrapper).
{
  lib,
  xcodeClang,
  hostQt, # build-platform qt6 scope at the same pin; supplies moc/rcc/qsb/...
  srcs, # the cross scope's srcs.nix
  appleSdk, # "iphonesimulator" | "iphoneos"
  arch, # CMAKE_OSX_ARCHITECTURES
}:

{
  pname,
  # iOS-built Qt modules this one links against; also propagated to consumers
  # so a single buildInputs entry pulls the whole static set.
  qtDeps ? [ ],
  nativeBuildInputs ? [ ],
  cmakeFlags ? [ ],
  # nixpkgs' patch set for the same source, minus the PATH-based plugin
  # lookup: it needs a NIXPKGS_QT_PLUGIN_PREFIX define only the cc-wrapper
  # injects, and dynamic plugin lookup is moot in a static build.
  patches ? builtins.filter (
    p: !(lib.hasSuffix "derive-plugin-load-path-from-PATH.patch" (baseNameOf (toString p)))
  ) (hostQt.${pname}.patches or [ ]),
  ...
}@args:

let
  inherit (srcs.${pname}) src version;
  qtPluginPrefix = "lib/qt-6/plugins";
  qtQmlPrefix = "lib/qt-6/qml";
  isQtbase = pname == "qtbase";
  qtbase = lib.findFirst (d: d.pname == "qtbase") null qtDeps;
in
xcodeClang.mkDerivation (
  removeAttrs args [ "qtDeps" ]
  // {
    inherit
      pname
      version
      src
      patches
      nativeBuildInputs
      ;

    propagatedBuildInputs = qtDeps;

    cmakeFlags = [
      "--log-level=STATUS"
      "-DCMAKE_OSX_ARCHITECTURES=${arch}"
      "-DQT_HOST_PATH=${hostQt.qtbase}"
      "-DQt6HostInfo_DIR=${hostQt.qtbase}/lib/cmake/Qt6HostInfo"
      "-DQT_BUILD_EXAMPLES=OFF"
      "-DQT_BUILD_TESTS=OFF"
      "-DQT_GENERATE_SBOM=OFF"
      # never pick up build-platform .pc files for the iOS host
      "-DFEATURE_pkg_config=OFF"
    ]
    ++ (
      if isQtbase then
        [
          "-DQT_QMAKE_TARGET_MKSPEC=macx-ios-clang"
          "-DQT_APPLE_SDK=${appleSdk}"
          "-DINSTALL_PLUGINSDIR=${qtPluginPrefix}"
          "-DINSTALL_QMLDIR=${qtQmlPrefix}"
        ]
      else
        [
          "-DCMAKE_TOOLCHAIN_FILE=${qtbase}/lib/cmake/Qt6/qt.toolchain.cmake"
          "-DQT_ADDITIONAL_PACKAGES_PREFIX_PATH=${lib.concatStringsSep ";" (map toString qtDeps)}"
        ]
    )
    ++ cmakeFlags;

    passthru = (args.passthru or { }) // {
      inherit qtPluginPrefix qtQmlPrefix appleSdk;
    };

    meta = {
      homepage = "https://www.qt.io/";
      description = "Qt ${pname} ${version} for iOS (${appleSdk}, static frameworks)";
      license = with lib.licenses; [
        fdl13Plus
        gpl2Plus
        lgpl21Plus
        lgpl3Plus
      ];
      platforms = lib.platforms.darwin;
    }
    // (args.meta or { });
  }
)
