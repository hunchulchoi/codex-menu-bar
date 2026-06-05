# Header Metadata & GitHub Link Integration

This specification details the changes required to display the application version, release date, and developer name (`by choihunchul`) next to the main status title in the Codex Menu Bar, and integrate the GitHub repository link `https://github.com/hunchulchoi/codex-menu-bar`.

## Proposed Approaches

We propose the following approaches to address the requirements:

### Approach 1: Clickable Status Header with Metadata (Recommended)
* **Metadata in Header**: The header menu item (index 0) dynamically shows `[Status Title] v[Version] ([Release Date]) by choihunchul`.
* **GitHub Link**: Make the header menu item clickable. Clicking it will open `https://github.com/hunchulchoi/codex-menu-bar` in the user's default browser.
* **Dedicated Menu Item**: To ensure the link is highly discoverable, we also add a dedicated menu item `GitHub Repository...` in the lower section of the menu (above `Settings...`).

### Approach 2: Static Status Header + Dedicated Menu Item Only
* **Metadata in Header**: Same as Approach 1, but the header item remains disabled/non-clickable.
* **GitHub Link**: The repository is only accessible through the dedicated `GitHub Repository...` menu item.

---

## Detailed Design (Approach 1)

### 1. Version & Build Date Retrieval in Swift
We will add two helper properties to `CodexMenuBarApp` in [main.swift](file:///Users/hunchulchoi/projects/workspace/myside/codex-menu-bar/Sources/CodexMenuBar/main.swift):
* `currentVersion`: Reads `CFBundleShortVersionString` from the application's bundle plist, falling back to `1.0.5` if running outside a bundle context.
* `buildDate`: Reads a custom `CFBuildDate` key from the bundle plist. If it does not exist, it falls back to the modification date of the executable, or the current date.

```swift
private var currentVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.5"
}

private var buildDate: String {
    if let plistDate = Bundle.main.infoDictionary?["CFBuildDate"] as? String {
        return plistDate
    }
    if let executableURL = Bundle.main.executableURL,
       let attributes = try? FileManager.default.attributesOfItem(atPath: executableURL.path),
       let modificationDate = attributes[.modificationDate] as? Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: modificationDate)
    }
    return "2026-06-05"
}
```

### 2. Updating the Menu Header & Adding the GitHub Selector
* In `configureMenu()`, we will initialize the header item with target and selector to open GitHub. We will also add the dedicated `GitHub Repository...` menu item.
* In `updateMenu()`, we will dynamically construct the title:
  ```swift
  let metadata = " v\(currentVersion) (\(buildDate)) by choihunchul"
  // headerTitle = [Base Title] + metadata
  ```

### 3. Injecting Build Date during Packaging
We will update both [package-app.mjs](file:///Users/hunchulchoi/projects/workspace/myside/codex-menu-bar/scripts/package-app.mjs) and [install-app.mjs](file:///Users/hunchulchoi/projects/workspace/myside/codex-menu-bar/scripts/install-app.mjs) to automatically get the current date (ISO date slice `YYYY-MM-DD`) and write it into the generated `Info.plist` file:
```xml
<key>CFBuildDate</key>
<string>2026-06-05</string>
```
We will also update `install-app.mjs` to dynamically read version arguments or default to `1.0.5`.

## Verification Plan

### Manual Verification
1. Run `swift build` and `swift test` to ensure there are no compilation or unit test errors.
2. Run `node scripts/install-app.mjs 1.0.5` to package, install, and launch the menu bar app.
3. Open the menu bar app and verify:
   * Header item displays: `Codex Menu Bar v1.0.5 (2026-06-05) by choihunchul`.
   * Clicking the header item opens the browser to `https://github.com/hunchulchoi/codex-menu-bar`.
   * A new menu item `GitHub Repository...` is visible and also opens the same URL.
