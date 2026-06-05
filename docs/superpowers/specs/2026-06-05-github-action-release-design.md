# Design Spec: Codex Menu Bar Release Workflow

This specification details the automation workflow for building, packaging, and releasing the Codex Menu Bar companion app as a macOS Disk Image (`.dmg`) file on GitHub.

## Workflow Goal
Automate the build and release process so that pushing a version tag (e.g., `v1.0.2`) compiles the Swift application, packages it into a standard macOS `.app` bundle, converts it into a premium `.dmg` installer, and publishes it to GitHub Releases.

## Proposed Components

### 1. `scripts/package-app.mjs` [NEW]
A dedicated script to handle building the binary and structure of the app bundle without interacting with the host system (no installation, registry, or launching).

* **Command**: `node scripts/package-app.mjs [version]`
* **Behavior**:
  1. Compiles the binary in release mode: `swift build -c release`
  2. Creates directory structure: `dist/CodexMenuBar.app/Contents/MacOS` and `dist/CodexMenuBar.app/Contents/Resources`
  3. Generates `AppIcon.icns` using `scripts/make-icns.swift` and copies it into `Resources`
  4. Writes `Info.plist` using the supplied `version` argument (defaulting to `1.0.0` if not provided)
  5. Copies the compiled binary to `dist/CodexMenuBar.app/Contents/MacOS/CodexMenuBar`

### 2. `.github/workflows/release.yml` [NEW]
GitHub Actions workflow configured to run on tag pushes.

* **Trigger**:
  - Pushing a tag that matches `v*` (e.g., `v1.2.0`).
  - Manual trigger via `workflow_dispatch`.
* **Runner**: `macos-14`
* **Workflow Steps**:
  1. **Checkout**: Check out the repository.
  2. **Set up Node.js**: Initialize Node environment.
  3. **Extract version**: Extract version string from GITHUB_REF (e.g., `refs/tags/v1.0.2` -> `1.0.2`).
  4. **Build App Bundle**: Run `node scripts/package-app.mjs <version>`.
  5. **Install `create-dmg`**: Run `brew install create-dmg`.
  6. **Build DMG**: Run `create-dmg` to create a beautiful disk image with layout configuration:
     ```bash
     create-dmg \
       --volname "Codex Menu Bar" \
       --volicon "dist/CodexMenuBar.app/Contents/Resources/AppIcon.icns" \
       --window-pos 200 120 \
       --window-size 600 400 \
       --icon-size 100 \
       --icon "CodexMenuBar.app" 175 120 \
       --hide-extension "CodexMenuBar.app" \
       --app-drop-link 425 120 \
       "dist/CodexMenuBar.dmg" \
       "dist/CodexMenuBar.app"
     ```
  7. **Create Release**: Create a GitHub Release and upload `dist/CodexMenuBar.dmg`.

## Verification Plan

### Automated Tests
* None. This is a deployment/release workflow configuration.

### Manual Verification
* Trigger the workflow using a test tag or via `workflow_dispatch` on GitHub once pushed.
* Download the generated `.dmg` on macOS, mount it, and verify that dragging to `/Applications` works and the app launches correctly.
