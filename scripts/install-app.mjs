#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(scriptDir, "..");
const binaryPath = path.join(projectRoot, ".build", "release", "CodexMenuBar");
const inputSvg = path.join(projectRoot, "assets", "icons", "idle.svg");
const generatorScript = path.join(projectRoot, "scripts", "make-icns.swift");

async function fileExists(file) {
  try {
    await fs.access(file);
    return true;
  } catch {
    return false;
  }
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    ...options,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} failed\n${result.stderr || result.stdout}`);
  }
  return result.stdout.trim();
}

async function main() {
  console.log("1. Building CodexMenuBar in release mode...");
  run("swift", ["build", "-c", "release"], { cwd: projectRoot });
  if (!(await fileExists(binaryPath))) {
    throw new Error(`Build finished but binary not found at ${binaryPath}`);
  }

  console.log("2. Determining target application directory...");
  let appsDir = "/Applications";
  let testPath = path.join(appsDir, ".write_test");
  let writable = false;
  try {
    await fs.writeFile(testPath, "test");
    await fs.unlink(testPath);
    writable = true;
  } catch {
    appsDir = path.join(os.homedir(), "Applications");
    console.log(`/Applications is not writeable. Falling back to ${appsDir}`);
    await fs.mkdir(appsDir, { recursive: true });
  }

  const appBundlePath = path.join(appsDir, "CodexMenuBar.app");
  console.log(`Target path: ${appBundlePath}`);

  console.log("3. Packaging CodexMenuBar.app bundle...");
  if (await fileExists(appBundlePath)) {
    console.log("Removing existing application bundle...");
    await fs.rm(appBundlePath, { recursive: true, force: true });
  }

  const macosDir = path.join(appBundlePath, "Contents", "MacOS");
  const resourcesDir = path.join(appBundlePath, "Contents", "Resources");
  await fs.mkdir(macosDir, { recursive: true });
  await fs.mkdir(resourcesDir, { recursive: true });

  // Copy binary
  await fs.copyFile(binaryPath, path.join(macosDir, "CodexMenuBar"));
  // Make binary executable
  await fs.chmod(path.join(macosDir, "CodexMenuBar"), 0o755);

  // Compile & Copy AppIcon.icns from idle.svg
  if (await fileExists(inputSvg) && await fileExists(generatorScript)) {
    console.log("Generating AppIcon.icns from assets/icons/idle.svg...");
    const tempIcns = path.join(projectRoot, "AppIcon.icns");
    try {
      run("swift", [generatorScript, inputSvg, tempIcns]);
      if (await fileExists(tempIcns)) {
        await fs.rename(tempIcns, path.join(resourcesDir, "AppIcon.icns"));
        console.log("AppIcon.icns successfully packaged.");
      }
    } catch (e) {
      console.error("Failed to generate AppIcon.icns:", e);
    }
  }

  // Write Info.plist
  const plistContent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CodexMenuBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.codex.menubar</string>
    <key>CFBundleName</key>
    <string>CodexMenuBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
`;
  await fs.writeFile(path.join(appBundlePath, "Contents", "Info.plist"), plistContent);

  console.log("4. Registering CodexMenuBar as a macOS Login Item...");
  try {
    run("osascript", ["-e", 'tell application "System Events" to delete (every login item whose name is "CodexMenuBar")']);
  } catch (e) {
    // Ignore errors if it didn't exist
  }
  run("osascript", ["-e", `tell application "System Events" to make login item at end with properties {name:"CodexMenuBar", path:"${appBundlePath}", hidden:false}`]);

  console.log("5. Launching CodexMenuBar application...");
  try {
    run("killall", ["CodexMenuBar"]);
    // Wait for macOS to clean up process resources
    await new Promise(resolve => setTimeout(resolve, 1000));
  } catch (e) {
    // Ignore if not running
  }
  run("open", ["-g", appBundlePath]);

  console.log("Success! CodexMenuBar installed and registered to start on login.");
}

main().catch((err) => {
  console.error("Installation failed:", err);
  process.exit(1);
});
