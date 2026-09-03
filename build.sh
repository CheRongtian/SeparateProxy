#!/bin/bash
/usr/bin/xcodebuild \
  -project macOS/SeparateProxy.xcodeproj \
  -scheme SeparateProxy \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/separateproxy-manual-derived \
  -allowProvisioningUpdates \
  build