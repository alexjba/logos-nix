# A CMake project built for iOS as static archives against the store Qt: the
# pure half of an app. Whatever needs Xcode's generator, code
# signing or simctl stays in an impure `nix run` on top of this.
{
  lib,
  xcodeClang,
  qt6,
  logosQtCrossToolchainFile,
  logosQtCrossCmakeFlags,
}:

{
  # sourceDir: the directory holding CMakeLists.txt, relative to src.
  sourceDir ? ".",
  cmakeFlags ? [ ],
  buildInputs ? [ ],
  postInstall ? "",
  ...
}@args:

xcodeClang.mkDerivation (
  removeAttrs args [ "sourceDir" ]
  // {
    cmakeDir = "../${sourceDir}";

    buildInputs = [
      qt6.qtbase
      qt6.qtdeclarative
      qt6.qtshadertools
      qt6.qtsvg
    ]
    ++ buildInputs;

    cmakeFlags = [
      "-DCMAKE_TOOLCHAIN_FILE=${logosQtCrossToolchainFile}"
    ]
    ++ logosQtCrossCmakeFlags
    ++ cmakeFlags;

    # Static is the contract: a dynamic image here is an archive
    # that silently became a plugin no iOS host can load.
    postInstall = ''
      _dynamic=$(find $out \( -name '*.dylib' -o -name '*.so' -o -name '*.framework' \))
      while IFS= read -r _f; do
        case "$_f" in *.a | *.o) continue ;; esac
        if otool -hv "$_f" 2>/dev/null | grep -qE '^\s*MH_MAGIC.*(DYLIB|BUNDLE|EXECUTE)'; then
          _dynamic="$_dynamic"$'\n'"$_f"
        fi
      done < <(find $out -type f)
      if [ -n "$_dynamic" ]; then
        echo "error: dynamic image in a static-only iOS stage:$_dynamic" >&2
        exit 1
      fi
      [ -n "$(find $out -name '*.a' -print -quit)" ] || { echo "error: no static archive installed" >&2; exit 1; }
    ''
    + postInstall;

    meta = {
      platforms = [ "aarch64-darwin" ];
    }
    // (args.meta or { });
  }
)
