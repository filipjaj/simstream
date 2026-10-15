# Security

SimStream turns a simulator into something anyone with a link can watch and, if you allow it, control. Read this before you share one.

## What a link grants

- The share URL is `https://<random>.trycloudflare.com/<token>/`. The token is 20 characters from a 32-letter alphabet (100 bits) and every route lives under it; requests without it get a 404, and every route returns 410 once the share ends.
- Anyone holding the link sees the screen. With **Viewers can control** on, they can tap, swipe, type and press hardware buttons. With **Viewers can switch simulators** on, they can move the stream to any other simulator on that Mac.
- A link dies when its lifetime runs out, when you stop the share, or when the app or CLI exits. Nothing is persisted on a server.

Treat a link like a password for that simulator for as long as it's live. Don't post it anywhere public.

## The simulator is not a sandbox

A viewer with control acts as a user of a device that sits on your Mac's network:

- **Your Mac's localhost and LAN are reachable.** Safari in the simulator can open `http://localhost:<port>` on the host and anything your Mac can reach on the local network, VPN included.
- **The pasteboard can be shared.** With Simulator's *Automatically Sync Pasteboard* on (the default), pasting in the simulator pastes your Mac's clipboard. Turn it off under Simulator > Edit before sharing with control.
- **Whatever is signed in is exposed.** Apps, Safari sessions, keychain items and photos in that simulator are all in reach.

Share a dedicated simulator with nothing signed in, and leave control off when people only need to watch.

## Keeping viewers in one app

**Keep viewers in** (`--lock-app <bundle-id>` in the CLI) narrows what a viewer with control can do. SimStream drops the Home, Lock and Siri buttons and drags that start on the top or bottom edge (Home, the app switcher, Control Centre, Notification Centre), and brings the app back to the front about once a second if anything else opens.

It's a guard rail, not a sandbox. A viewer can still get out of the app for up to a second or two, for example through a link that opens Safari. Anything inside the app, such as a web view, has the same network access as the rest of the simulator. In landscape, only the bring-back applies.

## Transport

- The local server binds to `127.0.0.1` only. Public access goes through a Cloudflare quick tunnel (`cloudflared`), which terminates TLS at Cloudflare. Cloudflare can see the stream; don't share anything you wouldn't send through it.
- Quick tunnels have no account, no access policy and no uptime guarantee. If you need access control, run `cloudflared` with a named tunnel behind Cloudflare Access instead.

## Remote hosts

Adding a remote Mac makes SimStream run commands there over your existing SSH config and keys, and copy its CLI to `~/.local/share/simstream` on that host. It has the same reach as you do over SSH.

## Reporting a vulnerability

Open a [private security advisory](../../security/advisories/new) on this repository rather than a public issue.
