# Parley — macOS PR Review App for Markdown Documents

default: launch

# Build and launch (default)
launch: app
  open build/Parley.app

# Build debug binary
build:
  swiftly run swift build

# Build optimized release binary
release:
  swiftly run swift build -c release

# Run all tests
test:
  swiftly run swift test

# Run specific test suite (e.g., just test-filter PRURLParser)
test-filter SUITE:
  swiftly run swift test --filter {{SUITE}}

# Install to /usr/local/bin (release build)
install: release
  @mkdir -p /usr/local/bin
  @mkdir -p /usr/local/lib/parley
  cp .build/arm64-apple-macosx/release/Parley /usr/local/bin/parley
  cp -R .build/arm64-apple-macosx/release/Parley_Parley.bundle /usr/local/lib/parley/
  @echo "installed parley to /usr/local/bin/parley"

# Uninstall from /usr/local/bin
uninstall:
  rm -f /usr/local/bin/parley
  rm -rf /usr/local/lib/parley
  @echo "uninstalled parley"

# Create a macOS .app bundle in build/
app: release
  #!/usr/bin/env bash
  set -euo pipefail
  app_dir="build/Parley.app/Contents"
  rm -rf build/Parley.app
  mkdir -p "${app_dir}/MacOS"
  mkdir -p "${app_dir}/Resources"
  cp .build/arm64-apple-macosx/release/Parley "${app_dir}/MacOS/Parley"
  cp -R .build/arm64-apple-macosx/release/Parley_Parley.bundle "${app_dir}/Resources/"
  cp Sources/Parley/Resources/AppIcon.icns "${app_dir}/Resources/AppIcon.icns"
  cat > "${app_dir}/Info.plist" << 'PLIST'
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>CFBundleExecutable</key>
    <string>Parley</string>
    <key>CFBundleIdentifier</key>
    <string>com.parley.app</string>
    <key>CFBundleName</key>
    <string>Parley</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
  </dict>
  </plist>
  PLIST
  codesign --force --deep -s - build/Parley.app
  echo "built build/Parley.app"

# Install .app to /Applications
install-app: app
  rm -rf /Applications/Parley.app
  cp -R build/Parley.app /Applications/Parley.app
  @echo "installed /Applications/Parley.app"

# Clean build artifacts
clean:
  swiftly run swift package clean
  rm -rf build/

# Format and lint (placeholder — add swiftformat/swiftlint when configured)
lint:
  @echo "no linter configured yet"
