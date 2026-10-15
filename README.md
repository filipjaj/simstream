# SimStream

Share a running iOS simulator at a public link. Viewers watch a low-latency H.264 stream in the browser or the native iOS viewer, and can take turns controlling it.

- **Mac app** (`mac/`): pick a simulator, share it, get a link and a QR code. Shares can also run on another Mac over SSH, so the link outlives your laptop's lid.
- **CLI** (`simstream`): the same engine, headless, for Macs you reach over SSH.
- **iOS viewer** (`ios/`): scan the QR code and use the simulator with real multi-touch.

Read [SECURITY.md](SECURITY.md) before sharing with control on. A link is full access to that simulator, and the simulator can reach your Mac's network.

## Requirements

- macOS 26 with Xcode 26 and an iOS 26 simulator runtime
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), [AXe](https://github.com/cameroncooke/AXe) and [cloudflared](https://github.com/cloudflare/cloudflared): `brew install xcodegen cameroncooke/axe/axe cloudflared`

## Install

```sh
mac/scripts/install.sh
```

This vendors AXe's frameworks, builds both targets and installs `~/Applications/SimStream.app` plus `~/.local/share/simstream` with a `simstream` symlink in `~/.local/bin`. Re-run it after `brew upgrade axe` or an Xcode update.

## CLI

```sh
simstream list
simstream start --name "iPhone 17" --minutes 15   # prints the link once it's live
simstream apps --udid <udid>                      # apps you can keep viewers in
simstream ctl lock com.example.app                # or start with --lock-app com.example.app
simstream ctl control off
simstream stop
```

`simstream share` runs in the foreground; `--no-tunnel` serves on 127.0.0.1 only.

## iOS viewer

```sh
cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig   # your team ID and bundle ID prefix
cd ios && xcodegen generate && open SimStreamViewer.xcodeproj
```

## How it works

SimStream links the FBSimulatorControl frameworks that ship with AXe. Input goes over a persistent HID connection (about 1 ms per event). Frames come from the simulator's framebuffer IOSurface, get encoded with VideoToolbox, and are decoded with WebCodecs in the browser or `AVSampleBufferDisplayLayer` on iOS, with JPEG as the fallback. The server binds to 127.0.0.1, and a Cloudflare quick tunnel makes it public.

The wire format is defined in three places that must change together: `mac/SimStream/Server/ViewerProtocol.swift`, `mac/SimStream/Resources/viewer.html` and `ios/SimStreamViewer/Model/ViewerProtocol.swift`.

## License

MIT. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for what the build pulls in.
