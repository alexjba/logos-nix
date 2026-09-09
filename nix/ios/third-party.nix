# The non-Qt dependency tail of liblogos_core as static archives for iOS,
# on Xcode's clang (xcode-clang.nix). nixpkgs' own iOS cross stdenv is not
# usable here: at this pin `pkgsIosSimulator.stdenv` fails building
# compiler-rt ("ln: failed to create symbolic link './lib': File exists")
# and targets the macOS SDK, so every archive below is built by hand.
#
# Header-only libraries (nlohmann_json, cli11, cpp-semver) are taken from
# the build platform's package set unchanged: their CMake config packages
# carry no platform-specific content.
{
  lib,
  xcodeClang,
  xcodeWrapper,
  pkgsBuildBuild,
  appleSdk, # "iphonesimulator" | "iphoneos"
  arch, # "arm64"
  deploymentTarget, # "17"
  # Source derivations from the cross scope (same pin as the native set).
  boostVersion,
  opensslSrc,
  opensslVersion,
  spdlogSrc,
  spdlogVersion,
  libsodiumSrc,
  libsodiumVersion,
}:

let
  # Target triple clang wants for this SDK.
  triple = "${arch}-apple-ios${deploymentTarget}" + lib.optionalString (appleSdk == "iphonesimulator") "-simulator";

  # -D flags every plain CMake project needs to target this SDK; Qt projects
  # get the same from qt.toolchain.cmake.
  cmakeTargetFlags = [
    "-DCMAKE_OSX_SYSROOT=${appleSdk}"
    "-DCMAKE_OSX_ARCHITECTURES=${arch}"
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=${deploymentTarget}"
    "-DBUILD_SHARED_LIBS=OFF"
  ];

  # For autotools/Configure builds: a compiler command line that already
  # carries the SDK and triple.
  ccEnv = ''
    export SDKROOT=$(xcrun --sdk ${appleSdk} --show-sdk-path)
    export CC="$(xcrun --sdk ${appleSdk} --find clang) -target ${triple} -isysroot $SDKROOT"
    export CXX="$(xcrun --sdk ${appleSdk} --find clang++) -target ${triple} -isysroot $SDKROOT"
    export CFLAGS="-O2"
    export CXXFLAGS="-O2"
  '';
in
{
  spdlog = xcodeClang.mkDerivation {
    pname = "spdlog-ios";
    version = spdlogVersion;
    src = spdlogSrc;
    cmakeFlags = cmakeTargetFlags ++ [
      "-DSPDLOG_BUILD_SHARED=OFF"
      "-DSPDLOG_BUILD_EXAMPLE=OFF"
      "-DSPDLOG_BUILD_TESTS=OFF"
      "-DSPDLOG_INSTALL=ON"
      "-DSPDLOG_FMT_EXTERNAL=OFF"
    ];
  };

  # Boost through its own CMake build. The boost.io release tarball nixpkgs
  # pins carries no CMakeLists.txt (checked: 1.89.0 fails "does not appear to
  # contain CMakeLists.txt"), so the GitHub "-cmake" archive of the same
  # version is fetched instead. Only what liblogos_core and logos-protocol
  # link: process and filesystem, plus asio/system headers; their
  # dependencies are pulled in by Boost's CMake automatically.
  boost = xcodeClang.mkDerivation {
    pname = "boost-ios";
    version = boostVersion;
    src = pkgsBuildBuild.fetchurl {
      url = "https://github.com/boostorg/boost/releases/download/boost-${boostVersion}/boost-${boostVersion}-cmake.tar.xz";
      hash = "sha256-Z6zsAtDRGLXenrRB9ftwezoc3YhL4AyiS5pzyZVRH3Q=";
    };
    # Boost.Process v2's shell parser is wordexp(3), which the iOS SDK marks
    # unavailable ("'wordexp' is unavailable: not available on iOS"); take
    # the ENOTSUP branch it already has for OpenBSD/Android. iOS-only set, so
    # matching on __APPLE__ is exact here.
    postPatch = ''
      substituteInPlace libs/process/src/shell.cpp \
        --replace-fail '!defined(__OpenBSD__) && !defined(__ANDROID__)' \
                       '!defined(__OpenBSD__) && !defined(__ANDROID__) && !defined(__APPLE__)'
    '';
    cmakeFlags = cmakeTargetFlags ++ [
      "-DBOOST_INCLUDE_LIBRARIES=process;filesystem;system;asio;dll;uuid"
      "-DBOOST_INSTALL_LAYOUT=system"
      "-DBUILD_TESTING=OFF"
      "-DBOOST_ENABLE_MPI=OFF"
      "-DBOOST_ENABLE_PYTHON=OFF"
      "-DBOOST_RUNTIME_LINK=static"
    ];
    # Boost.DLL is header-only and its CMakeLists installs nothing even when
    # listed (checked: "libraries included: ...;dll" and no boost/dll/ in
    # the prefix); logos-module-loader-qt includes it, so copy the tree.
    postInstall = ''
      cp -r ../libs/dll/include/boost/. $out/include/boost/
    '';
  };

  # OpenSSL's own Configure knows the iOS SDKs; it shells out to xcrun, which
  # the version-gated wrapper provides.
  openssl = xcodeClang.mkDerivation {
    pname = "openssl-ios";
    version = opensslVersion;
    src = opensslSrc;
    nativeBuildInputs = [ pkgsBuildBuild.perl ];
    dontUseCmakeConfigure = true;
    configurePhase = ''
      runHook preConfigure
      export SDKROOT=$(xcrun --sdk ${appleSdk} --show-sdk-path)
      perl ./Configure ${if appleSdk == "iphonesimulator" then "iossimulator-arm64-xcrun" else "ios64-xcrun"} \
        no-shared no-tests no-apps no-docs no-module no-dso \
        ${if appleSdk == "iphonesimulator" then "-mios-simulator-version-min" else "-mios-version-min"}=${deploymentTarget} \
        --prefix=$out --openssldir=$out/etc/ssl --libdir=lib
      runHook postConfigure
    '';
    buildPhase = ''
      runHook preBuild
      make -j''${NIX_BUILD_CORES:-8} build_libs
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      make install_dev
      runHook postInstall
    '';
  };

  libsodium = xcodeClang.mkDerivation {
    pname = "libsodium-ios";
    version = libsodiumVersion;
    src = libsodiumSrc;
    nativeBuildInputs = [ pkgsBuildBuild.autoreconfHook ];
    dontUseCmakeConfigure = true;
    dontUseNinjaBuild = true;
    dontUseNinjaInstall = true;
    # libsodium's configure probes the SDK's target; the host triple is what
    # config.sub accepts, the -target in CC is what actually selects iOS.
    preConfigure = ccEnv;
    configureFlags = [
      "--host=aarch64-apple-darwin"
      "--disable-shared"
      "--enable-static"
      "--disable-ssp"
      "--disable-asm"
      "--with-pic"
    ];
  };
}
