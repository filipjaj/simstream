#!/bin/zsh
# Vendors AXe's frameworks, builds SimStream.app and the headless `simstream` CLI, and installs:
#   ~/Applications/SimStream.app
#   ~/.local/share/simstream/{simstream,viewer.html,Frameworks/}  (+ ~/.local/bin/simstream symlink)
# Remote hosts get a copy of ~/.local/share/simstream over SSH. Re-run after `brew upgrade axe` or an Xcode update.
set -euo pipefail
cd "${0:A:h}/.."
./scripts/vendor-axe.sh
xcodegen generate --quiet
for scheme in SimStream SimStreamCLI; do
  xcodebuild -project SimStream.xcodeproj -scheme $scheme -configuration Release -derivedDataPath build -quiet build
done

mkdir -p ~/Applications
rm -rf ~/Applications/SimStream.app
cp -R build/Build/Products/Release/SimStream.app ~/Applications/

CLI=~/.local/share/simstream
rm -rf $CLI && mkdir -p $CLI ~/.local/bin
cp build/Build/Products/Release/simstream-cli $CLI/simstream
cp SimStream/Resources/viewer.html $CLI/
cp -R Vendor/Frameworks $CLI/Frameworks
ln -sf $CLI/simstream ~/.local/bin/simstream
# simshare wraps a private `mini` tool and isn't part of the public repo.
[[ -x scripts/simshare ]] && ln -sf "$PWD/scripts/simshare" ~/.local/bin/simshare
echo "Installed ~/Applications/SimStream.app and $CLI (simstream on PATH)"
