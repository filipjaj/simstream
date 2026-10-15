# Third-party software

This repository contains no third-party code. At build time, `mac/scripts/vendor-axe.sh` copies frameworks from your local AXe install into `mac/Vendor/Frameworks` (git-ignored), patches their Swift interfaces and rewrites their install names. Those frameworks end up inside the built app and CLI.

If you distribute a built SimStream.app or `simstream` binary, include these notices:

| Component | Source | License |
| --- | --- | --- |
| FBControlCore, FBSimulatorControl, XCTestBootstrap, FBDeviceControl | [facebook/idb](https://github.com/facebook/idb), as shipped by AXe | MIT |
| AXe | [cameroncooke/AXe](https://github.com/cameroncooke/AXe) | MIT |

`cloudflared` ([cloudflare/cloudflared](https://github.com/cloudflare/cloudflared), Apache-2.0) runs as a separate process and is not bundled.

`mac/Vendor/Shim/CoreSimulator` holds opaque placeholder declarations written for this project, not Apple headers.
