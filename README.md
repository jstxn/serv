<p align="center">
  <img width="513" height="367" alt="Screenshot 2026-04-27 at 10 59 40 AM" src="https://github.com/user-attachments/assets/d348f4b8-09d3-43a1-8f09-cea91bca00aa" />
</p>

# Serv

Serv is a small macOS menu bar app for starting, stopping, and inspecting project dev servers.

## Install

1. Download `Serv.app.zip` from the latest release:
   https://github.com/jstxn/serv/releases/latest
2. Unzip it.
3. Move `Serv.app` to Applications.
4. Open Serv from Applications.

Current builds are unsigned, so macOS may require right-clicking `Serv.app` and choosing Open the first time.

## Use

Serv appears only in the macOS menu bar.

- Use `Add Project...` to choose a project directory.
- Start or stop detected command profiles from the project menu.
- Use `Manage Projects...` for search, filters, hidden profiles, env vars, health URLs, logs, and dependency checks.

Serv detects:

- Root `package.json` scripts
- Root `Makefile` targets
- Docker Compose projects and services
- Nested `package.json` projects in monorepos
- Manual custom commands when auto-detection misses

For JavaScript projects, Serv picks the package runner from lockfiles in this order: `pnpm`, `yarn`, `bun`, then `npm`.

## Develop

Run from source:

```sh
swift run Serv
```

Build a local app bundle:

```sh
make app
open .build/Serv.app
```

Create a local release zip:

```sh
make package
```

## Release

Pushing a version tag builds and publishes a GitHub Release:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The release workflow runs tests, packages `Serv.app.zip`, and attaches it to the release. Signing and notarization are not configured yet.

## License

MIT
