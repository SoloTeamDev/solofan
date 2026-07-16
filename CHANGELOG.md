# Changelog

All notable changes to SoloFan will be documented in this file.

## [1.6.6] - 2026-07-16

### Fixed
- **Release signing**: GitHub Actions now Developer ID–signs the app, nested `smc-helper` / `smc-write`, and DMG, then notarizes and staples (fixes Gatekeeper “Apple could not verify”).
- **CI workflow YAML**: Quoted `CODESIGN_IDENTITY` so the release workflow validates.

### Changed
- Bumped app version to **1.6.6** (`MARKETING_VERSION`) and build number to **10**.

## [1.6.5] - 2026-07-16

### Fixed
- **Menu bar popover**: Left-click opens the dashboard again. A contradictory guard required content to exist before show, which blocked the lazy content factory (content is intentionally `nil` until open).

### Changed
- Bumped app version to **1.6.5** (`MARKETING_VERSION`) and build number to **9**.
- **Distribution signing**: Release builds are now **Developer ID signed and notarized** (app + DMG), including nested `smc-helper` / `smc-write` binaries. GitHub Actions uses Developer ID + App Store Connect API key instead of ad-hoc `codesign -`.

## [1.6.4] - 2026-07-16

### Fixed
- **M4/M5 fan control**: Manual control now works when Apple Silicon keeps fans in thermalmonitord “system mode” — unlocks via verified mode writes and `Ftst` when needed.
- **Apple Silicon die temperatures**: CPU/GPU use the hottest real die-cluster sensors (`Tp**` / `Te**` / `Tg**`) instead of gated cores that read ~1–2°C.
- **GPU temp flicker**: Holds the last valid GPU reading across power-gating instead of dropping to near-zero.
- **Auto max-speed**: Persists the automatic-mode maximum across launches.
- **Menu bar icon**: Renders as a proper template image and no longer animates (clears tinting and CPU churn).
- **Popover lifecycle**: Builds content lazily, releases it on close, and waits until content is attached before showing.
- **SMC helper**: Fan-only, bounded, clamped writes; stronger privilege fallback for `runSmcHelper`.

### Changed
- Bumped app version to **1.6.4** (`MARKETING_VERSION`) and build number to **8**.
- Removed unused `UserDefaultsManager`.

## [1.6.3] - 2026-07-15

### Changed
- Bumped app version metadata to **1.6.3** (`MARKETING_VERSION`) and build number to **7**.
- Updated release-facing documentation to reference **v1.6.3** consistently.

## [1.6.2] - 2026-05-26

### Changed
- **Settings UI**: Replaced animated mesh gradient with flat window background.
- **Settings sidebar**: Wider floating Liquid Glass panel (268pt) with full-height glass, larger tab rows, and tint selection inside the panel.

## [1.6.1] - 2026-05-24

### Changed
- **Settings (Liquid Glass HIG)**: Rewritten with native `NavigationSplitView` sidebar, grouped `Form` content (no glass-on-glass), mesh backdrop, and glass toolbar actions per [Liquid Glass Reference](https://github.com/conorluddy/LiquidGlassReference).

## [1.6.0] - 2026-05-24

### Added
- **App icon**: SoloFanIcon populated from `docs/assets/logo.png` via `scripts/generate-app-icon.sh`.
- **Widget dashboard**: iOS-style editable popover layout — add/remove widgets, drag reorder, 1–2 columns per row.
- **Desktop adaptive UI**: GPU temperature / system load cards when no battery is present.
- **Edit mode**: Footer **Edit/Done** button replaces the Startup toggle (launch at login remains in Settings).

### Changed
- **Settings Liquid Glass**: Refactored to `NavigationSplitView` — glass on navigation only, plain grouped content panels.
- **Status bar power mode**: Falls back to fan % or temperature on desktop Macs without battery data.
- Consolidated asset catalog under `fan/Assets.xcassets/`.
- **Dashboard edit UX**: Layout-engine drop targeting, drag preview from measured sizes, **Reset** to default layout, no jiggle animation in edit mode.

## [1.5.0] - 2026-05-24

### Added
- **SoloFan rebrand**: App display name, bundle product name (`SoloFan.app`), and **SoloFanIcon** asset catalog.
- **Liquid Glass settings**: Native macOS 26 glass UI with sidebar navigation and animated mesh backdrop.
- **Menu bar context menu**: Open Settings, Hide Icon, Close App.
- **Hidden menu bar mode**: Reopen app to show settings; toggle to show icon again.

### Changed
- Release artifacts renamed to `solofan-v*.{zip,dmg}` with `SoloFan.app` inside.
- Install script updated for SoloFan paths and archive names.

## [1.4.0] - 2026-05-10

### Added
- **Per-fan manual control**: Optional separate target sliders when multiple fans are detected.
- **`FanRPMBounds`**: Central documented RPM limits and SMC fallbacks.

### Fixed
- **Fan max/min reporting**: UI and automatic mode now use **per-fan SMC** (`F%dMn` / `F%dMx`) instead of a hardcoded Intel-style **6500 RPM** ceiling; percentages and status bar scale to real ranges.
- **SMC fan max fallback**: If one fan’s maximum cannot be read, reuse the best peer reading before using a conservative default.

### Changed
- **Documentation / compatibility**: README and docs now state **macOS 26.1+**, matching `MACOSX_DEPLOYMENT_TARGET` in `fan.xcodeproj` (replacing outdated “macOS 11 / 13” wording for current builds).
- GitHub Actions release notes template updated for the same OS requirement.

## [1.3.0] - 2026-01-16

### Added
- **Settings Window**: New comprehensive settings panel accessible from the menu bar popover
- **Status Bar Display Modes**: Choose what to display in menu bar (None, Temperature, Power Usage, Fan Speed %)
- **High Temperature Alerts**: Configurable temperature threshold with system notifications
- **Auto Mode Switching**: Automatically switch to automatic control when temperatures exceed threshold
- **Monitoring Interval Control**: Adjustable refresh rate for temperature monitoring (0.5-5.0 seconds)
- **Launch at Login Toggle**: Easy enable/disable in settings UI

### Improved
- Settings UI with liquid glass design matching app aesthetics
- Real-time settings application without restart
- Better organization of app preferences

### Fixed
- **Status bar display crash**: Fixed crash caused by invalid SMC data parsing ("Negative value is not representable"). Added validation to SMC reads to avoid corrupt sizes.
- **Status bar dynamic text**: Rewrote `StatusBarManager` to properly render dynamic text and animation; fixed issues where Power Usage display wasn't updating.

### Improved
- **Status bar compactness**: Shortened and compacted menu bar text, added compact font and option to show image-only for minimal footprint.
- **Power Usage display**: Shows battery power in Watts (`W`) when available, falls back to fan speed percentage when not available.
- **Robustness**: Improved SMC parsing and added defensive checks to prevent crashes and layout errors.

## [1.2.4] - 2026-01-16

### Fixed
- **Wake/Unlock Resume**: Fixed automatic mode not reapplying fan settings after subsequent wake/unlock events
- Settings now apply immediately on wake without waiting for temperature readings
- Uses last applied speed or safe default (3000 RPM) when temperature not yet available

## [1.2.3] - 2026-01-16

### Fixed
- **Unlock Detection**: Added proper macOS unlock detection using `DistributedNotificationCenter`
- Now listens to `com.apple.screenIsUnlocked` for reliable unlock events
- Added `sessionDidBecomeActiveNotification` as fallback for session activation

## [1.2.2] - 2026-01-16

### Fixed
- **Startup Settings**: Wait for fans detection before applying control settings
- Use Combine to observe `numberOfFans` and apply settings when > 0
- Add retry mechanism in `reapplySettings` for wake scenarios

## [1.2.1] - 2026-01-16

### Fixed
- Settings not applying on app start
- Added `applyInitialSettings()` called from init

## [1.2.0] - 2026-01-16

### Added
- **Sleep/Wake Support**: App now properly handles system sleep and wake events
- Restores system control on sleep/lock
- Reapplies user settings on wake/unlock
- Uses NSWorkspace notifications for comprehensive event detection

## [1.1.2] - 2026-01-15

### Added
- One-liner install script: `curl -fsSL ... | bash`
- Opens ffan.app automatically after installation

## [1.1.1] - 2026-01-15

### Improved
- Landing page design
- Added GUI installation instructions

## [1.1.0] - 2026-01-15

### Added
- Gumroad integration for distribution
- Updated landing page with download buttons

## [1.0.6] - 2026-01-15

### Fixed
- Installation instructions - corrected helper tool path

## [1.0.5] - 2026-01-15

### Fixed
- Release notes path corrections

## [1.0.4] - 2026-01-15

### Improved
- Documentation updates
- Intel support verification

## [1.0.0] - 2026-01-14

### Added
- Initial release
- Temperature monitoring (CPU/GPU)
- Fan speed control (manual/automatic)
- Menu bar integration
- Launch at login support
- Privileged helper tool for SMC access
- Liquid glass UI design
