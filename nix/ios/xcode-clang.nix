# Compiling for iOS: Xcode's clang through the version-gated wrapper, never
# nix's cc-wrapper (measured 2026-09-07: it adds -mmacos-version-min and the
# macOS sysroot, which Apple clang rejects beside -mios-*-version-min).
{
  stdenvNoCC,
  xcodeWrapper,
  cmake,
  ninja,
  appleSdk, # "iphonesimulator" | "iphoneos"
}:

{
  # stdenvNoCC.mkDerivation with the iOS defaults underneath; every attribute
  # can still be overridden by the caller.
  mkDerivation =
    {
      nativeBuildInputs ? [ ],
      ...
    }@attrs:
    stdenvNoCC.mkDerivation (
      {
        __noChroot = true;
        strictDeps = true;
        enableParallelBuilding = true;

        nativeBuildInputs = [
          xcodeWrapper
          cmake
          ninja
        ]
        ++ nativeBuildInputs;

        preConfigure = ''
          export CC=$(xcrun --sdk ${appleSdk} --find clang)
          export CXX=$(xcrun --sdk ${appleSdk} --find clang++)
          export AR=$(xcrun --sdk ${appleSdk} --find ar)
          export RANLIB=$(xcrun --sdk ${appleSdk} --find ranlib)
          export STRIP=$(xcrun --sdk ${appleSdk} --find strip)
          # mkDerivation appends -DCMAKE_SYSTEM_NAME=Generic for any cross host
          # whose uname.system is null (iOS); cmakeFlagsArray lands after it.
          cmakeFlagsArray+=(-DCMAKE_SYSTEM_NAME=iOS)
        '';

        dontStrip = true;
        dontWrapQtApps = true;
      }
      // removeAttrs attrs [ "nativeBuildInputs" ]
    );
}
