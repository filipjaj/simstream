#!/bin/zsh
# Vendors AXe's frameworks, builds SimStream.app and the headless `simstream` CLI, and installs:
#   ~/Applications/SimStream.app
#   ~/.local/share/simstream/{simstream,viewer.html,Frameworks/}  (+ ~/.local/bin/simstream symlink)
# Remote hosts get a copy of ~/.local/share/simstream over SSH. Re-run after `brew upgrade axe` or an Xcode update.
set -euo pipefail
cd "${0:A:h}/.."

# Check everything up front, so a missing tool is one clear message instead of a build error.
problems=() packages=()
(( ${$(sw_vers -productVersion)%%.*} >= 26 )) || problems+=("SimStream needs macOS 26 or later.")
if [[ $(xcode-select -p 2>/dev/null) != *.app/Contents/Developer ]]; then
  problems+=("Select Xcode, not the Command Line Tools: sudo xcode-select -s /Applications/Xcode.app")
elif (( ${$(xcodebuild -version 2>/dev/null | awk 'NR==1 {print $2}')%%.*} < 26 )); then
  problems+=("SimStream needs Xcode 26 or later.")
fi
command -v xcodegen >/dev/null || packages+=(xcodegen)
if [[ -z ${AXE_FRAMEWORKS-} ]] && ! { command -v brew >/dev/null && [[ -d $(brew --prefix axe 2>/dev/null)/libexec/Frameworks ]] }; then
  packages+=(cameroncooke/axe/axe)
fi
command -v cloudflared >/dev/null || [[ -x /opt/homebrew/bin/cloudflared ]] || packages+=(cloudflared)
if (( ${#packages} )); then
  command -v brew >/dev/null || problems+=("Install Homebrew from https://brew.sh, then run the next line.")
  problems+=("Install the build tools: brew install ${packages[*]}")
fi
if (( ${#problems} )); then
  print -u2 "Can't install SimStream yet:"
  printf '  - %s\n' $problems >&2
  exit 1
fi

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
