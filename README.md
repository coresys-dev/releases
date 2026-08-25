CORE Tools is a clean, lightweight suite of creative tools made for video editors, content creators, and post-production workflows. The goal is simple: provide small, focused apps that help with editing, without turning the workflow into an absolute mess.

## What this repo is

This repo hosts **releases and media** for every CORE Tools app: build artifacts as GitHub Release assets, and app icons/screenshots/descriptions in `manifest.json` for the launcher's store view.

## Layout

```
manifest.json          # store manifest, consumed by the launcher (see below)
manifest.schema.json   # JSON Schema for manifest.json
<app-id>/
  icon/icon.png         # app icon/logo
  screenshots/1.png     # up to 3 presentation screenshots
  screenshots/2.png
  screenshots/3.png
ARTIFACTS/              # gitignored — local staging area for release builds
  <app-id>/
    win/<version>/       # Windows build output for that version
    mac/<version>/       # macOS build output for that version
scripts/
  release.ps1           # cuts a draft GitHub release for one app
```

## manifest.json

Fetched by the launcher (e.g. via `raw.githubusercontent.com/coresys-dev/releases/main/manifest.json`) to populate the app store: list, icons, screenshots, and the description page. Each entry in `apps` looks like:

```json
{
  "id": "core",
  "name": "CORE",
  "tagline": "Short one-line pitch",
  "description": "Longer text for the app's detail page",
  "category": "creative-suite",
  "platforms": ["windows", "macos"],
  "releaseTagPrefix": "core-v",
  "homepage": "",
  "changelog": "",
  "media": {
    "icon": "core/icon/icon.png",
    "screenshots": ["core/screenshots/1.png", "core/screenshots/2.png", "core/screenshots/3.png"]
  }
}
```

`media` paths are repo-relative; the launcher resolves them against `raw.githubusercontent.com/<repo>/main/<path>`. `homepage` is an optional link to the app's own marketing page (leave empty if none); `changelog` is plain text, not a link. See `manifest.schema.json` for the full schema.

## Releasing an app

Builds are staged locally (never committed) and pushed to GitHub as a **draft** release for manual review before publishing.

1. Build the app and drop the platform's artifacts into `ARTIFACTS\<app-id>\win\<version>\` and/or `ARTIFACTS\<app-id>\mac\<version>\`. At least one platform is required; both can be released together in one run.
2. Run:
   ```powershell
   .\scripts\release.ps1 -AppId core -Version 1.4.2 -Notes "Fix crash on export"
   ```
3. Check the generated **draft** release on GitHub (assets, notes, generated `latest.json`), then publish it manually once it looks right.

Run `.\scripts\release.ps1` with no arguments to list app ids and any folders currently staged in `ARTIFACTS\`. Add `-DryRun` to preview the plan (tag, assets, generated `latest.json`) without touching GitHub. Use `-NotesFile <path>` instead of `-Notes` to pull release notes from a changelog file.

### Tagging scheme

Releases are tagged `<app-id>-v<version>` (e.g. `core-v1.4.2`, `sldr-v0.9.0`) so every app can release independently from this single repo without colliding. Versions must be semver (`x.y.z` or `x.y.z-suffix`).

### Auto-update (`latest.json`)

Each release gets a generated `latest.json` asset for the launcher's update checker, with a section per platform actually included in that release:

```json
{
  "id": "core",
  "name": "CORE",
  "version": "1.4.2",
  "notes": "Fix crash on export",
  "pub_date": "2026-08-26T12:00:00Z",
  "platforms": {
    "windows": {
      "assets": [
        { "name": "CORE-Setup-1.4.2.exe", "url": "https://github.com/coresys-dev/releases/releases/download/core-v1.4.2/CORE-Setup-1.4.2.exe", "size": 12345678 }
      ]
    },
    "macos": {
      "assets": [
        { "name": "CORE-1.4.2.dmg", "url": "https://github.com/coresys-dev/releases/releases/download/core-v1.4.2/CORE-1.4.2.dmg", "size": 12345678 }
      ]
    }
  }
}
```

The launcher checks for updates by listing releases for the app's `releaseTagPrefix` via the GitHub API, taking the newest **published, non-draft** one, reading its `latest.json` asset, and picking the `platforms` entry matching the user's OS. Because releases start as drafts, nothing is visible to the auto-updater until it's published manually. Asset file names must be unique across platforms within a release (the script checks this).

Requires the [GitHub CLI](https://cli.github.com/) (`gh`), authenticated (`gh auth login`) with push access to this repo.
