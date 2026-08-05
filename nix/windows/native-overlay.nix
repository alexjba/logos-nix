# Windows cross support — BUILD-side fixes.
#
# Applied via `overlays` (NOT `crossOverlays`) because it has to take effect on
# the build-platform package set too.  It is only ever passed to the dedicated
# `mkWindowsPkgs` import, so it never reaches a normal native build.
final: prev:

{
  # glib's `withIntrospection` defaults to
  #     stdenv.targetPlatform.emulatorAvailable buildPackages
  #  && stdenv.hostPlatform.emulatorAvailable buildPackages
  # and `lib.systems.selectEmulator` answers "wine64" for a Windows target the
  # build platform cannot execute — which FORCES the wine64 derivation to
  # evaluate.  wine64.meta.platforms is [x86_64-linux x86_64-darwin]: no
  # aarch64-darwin, so evaluation throws on the team's Macs.
  #
  # It fires via targetPlatform on the NATIVE glib as well, which is why this
  # cannot live in the cross overlay.
  glib = prev.glib.override { withIntrospection = false; };
}
