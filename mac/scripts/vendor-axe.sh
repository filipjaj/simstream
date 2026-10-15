#!/bin/zsh
# Copies AXe's FBSimulatorControl frameworks into Vendor/Frameworks so the app
# embeds its own copy and survives `brew upgrade axe`.
#
# The shipped .swiftinterface files don't rebuild with a newer Swift compiler:
# `FBSimulatorControl` is both the module and a class in it, so qualified names
# like `FBSimulatorControl.FBSimulator` resolve against the class. We strip the
# module qualifier, drop the prebuilt .swiftmodule binaries (compiler-locked),
# and rewrite absolute install names to @rpath.
set -euo pipefail
cd "${0:A:h}/.."
SRC=${AXE_FRAMEWORKS:-$(brew --prefix axe)/libexec/Frameworks}
DST=Vendor/Frameworks
rm -rf $DST && mkdir -p $DST
cp -R $SRC/{FBControlCore,FBSimulatorControl,XCTestBootstrap,FBDeviceControl}.framework $DST/

for iface in $DST/*.framework/Modules/*.swiftmodule/*.swiftinterface; do
  perl -pi -e '
    next if /^(\@_exported )?import |swift-module-flags/;
    s/\bFBSimulatorControl\.FBSimulatorControl\b/FBSimulatorControl/g;
    s/\bFBSimulatorControl\.(?=[A-Z_])//g;
    s/\bIOSurface\.IOSurface\b/IOSurface/g;
  ' $iface
done
rm -f $DST/*.framework/Modules/*.swiftmodule/*.swiftmodule

for f in FBControlCore FBSimulatorControl XCTestBootstrap FBDeviceControl; do
  bin=$DST/$f.framework/Versions/A/$f
  install_name_tool -id @rpath/$f.framework/Versions/A/$f $bin 2>/dev/null
  codesign --force --sign - $DST/$f.framework >/dev/null 2>&1
done
echo "Vendored AXe $(axe --version 2>/dev/null || echo '?') frameworks into $DST"
