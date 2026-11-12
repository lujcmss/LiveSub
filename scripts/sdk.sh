# Sourced by the build and test scripts.
# With only the Command Line Tools installed, the newest SDK (macOS 27) makes SwiftUI's @State
# a compiler macro whose plugin ships only with Xcode. Building against the macOS 26 SDK, which
# matches the OS this app targets, avoids that. With Xcode selected, the default SDK is fine.
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p)" == /Library/Developer/CommandLineTools* ]]; then
  for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
    [[ -d "$sdk" ]] && export SDKROOT="$(cd "$sdk" && pwd -P)"
  done
fi
