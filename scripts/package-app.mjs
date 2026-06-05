#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
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
  const version = process.argv[2] || "1.0.0";
  console.log(`Building version ${version}...`);

  console.log("1. Building CodexMenuBar in release mode...");
  run("swift", ["build", "-c", "release"], { cwd: projectRoot });
  if (!(await fileExists(binaryPath))) {
    throw new Error(`Build finished but binary not found at ${binaryPath}`);
  }

  const distDir = path.join(projectRoot, "dist");
  const appBundlePath = path.join(distDir, "CodexMenuBar.app");
  console.log(`Packaging CodexMenuBar.app bundle to ${appBundlePath}...`);

  // Recreate clean dist directory
  await fs.rm(distDir, { recursive: true, force: true });
  
  const macosDir = path.join(appBundlePath, "Contents", "MacOS");
  const resourcesDir = path.join(appBundlePath, "Contents", "Resources");
  await fs.mkdir(macosDir, { recursive: true });
  await fs.mkdir(resourcesDir, { recursive: true });

  // Copy binary and set executable permission
  await fs.copyFile(binaryPath, path.join(macosDir, "CodexMenuBar"));
  await fs.chmod(path.join(macosDir, "CodexMenuBar"), 0o755);

  // Compile & Copy AppIcon.icns from idle.svg
  if (await fileExists(inputSvg) && await fileExists(generatorScript)) {
    console.log("Generating AppIcon.icns...");
    const tempIcns = path.join(projectRoot, "AppIcon.icns");
    try {
      run("swift", [generatorScript, inputSvg, tempIcns]);
      if (await fileExists(tempIcns)) {
        await fs.rename(tempIcns, path.join(resourcesDir, "AppIcon.icns"));
        console.log("AppIcon.icns successfully packaged.");
      }
    } catch (e) {
      console.error("Failed to generate AppIcon.icns:", e);
      throw e;
    }
  } else {
    console.warn("SVG or icon generator script missing.");
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
    <string>${version}</string>
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
  console.log("Info.plist generated successfully.");
  console.log("Packaging finished successfully.");
}

main().catch((err) => {
  console.error("Packaging failed:", err);
  process.exit(1);
});
