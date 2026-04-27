# Serv

Serv is a small macOS menu bar app for starting and stopping project dev servers.

## Download

Download the latest `Serv.app.zip` from GitHub Releases:

https://github.com/jstxn/serv/releases

Unzip it, move `Serv.app` to Applications, then open it. Current builds are unsigned, so macOS may require right-clicking `Serv.app` and choosing Open the first time.

## Run

```sh
swift run Serv
```

## Build A Mac App

```sh
make app
open .build/Serv.app
```

To create a distributable zip locally:

```sh
make package
```

The app appears only in the macOS menu bar. Use `Add Project...` to choose a project directory. Serv detects a command from `package.json` scripts first, then matching `Makefile` targets.

Serv saves one project with multiple command profiles when it finds them. Each profile has its own start or stop item in the project submenu.

Project menus stay small:

- Profiles are grouped by Compose, Frontend, API, Worker, Custom, and Other.
- Favorite profiles appear in a Favorites group.
- Hidden profiles stay out of the menu but remain editable in the management window.
- Running profiles show Starting, Ready, Running, Exited, or Failed when Serv owns the process.
- Last-error previews appear in the profile submenu after a process exits or fails.
- Externally running ports or Docker Compose services can be stopped after Serv shows project-aware details.

Use `Manage Projects...` for the larger monorepo workflow. The management window supports search, type filters, favorite and hidden toggles, editable profile names, groups, health URLs, env vars, log opening, and dependency checks.

Command detection currently includes:

- Root `package.json` scripts
- Root `Makefile` targets
- Docker Compose projects with `docker compose up`
- Docker Compose service profiles from `services:`
- Nested `package.json` projects below the selected folder
- Manual custom commands when auto-detection misses

1. `dev`
2. `start`
3. `serve`
4. `preview`
5. `web`
6. `server`

For JavaScript projects, Serv picks the package runner from lockfiles in this order: `pnpm`, `yarn`, `bun`, then `npm`.

Custom commands run with `/bin/zsh -lc` from the saved project directory.

## Release

Pushing a version tag builds and publishes a GitHub Release:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The release workflow runs tests, packages `Serv.app.zip`, and attaches it to the release. Signing and notarization are not configured yet.
