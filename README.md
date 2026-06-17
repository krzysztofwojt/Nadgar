# WristAssist

WristAssist is a native SwiftUI iPhone + Apple Watch MVP for talking to OpenAI Realtime from Apple Watch.

## What Is Implemented

- iPhone app for provider settings and OpenAI API key storage in Keychain.
- Apple Watch app with a single start/stop voice control.
- WatchConnectivity bridge where iPhone syncs settings plus the OpenAI API key to the paired Watch.
- iPhone-side token minting with `POST https://api.openai.com/v1/realtime/client_secrets`.
- Watch-side API key storage in Keychain and direct WebSocket connection to `wss://api.openai.com/v1/realtime?model=gpt-realtime-2`.
- Shared Swift package target for Realtime models, events, WatchConnectivity messages, and PCM16 conversion.
- Unit test files for shared contracts, plus a framework-free smoke-test executable for environments without full Xcode.

## Auth Model

The functional MVP path is bring-your-own OpenAI Platform API key.

The raw API key is stored on iPhone in Keychain and synced to the paired Watch, where it is also stored in Keychain. This lets the Watch start a Realtime session without an active iPhone connection after the key has synced once.

The ChatGPT/Codex option is shown in the iPhone UI but disabled. Codex OAuth/access tokens are scoped to Codex workflows, not general OpenAI API or Realtime API calls.

## Requirements

- Full Xcode with iOS 18 and watchOS 11 SDKs.
- A physical Apple Watch is recommended for the first end-to-end audio test.
- An OpenAI Platform API key with Realtime access.

This workspace was initially created on a machine with Command Line Tools only, so full app build verification must be run after Xcode is installed and selected.

## Verify

Validate plist and project syntax:

```sh
plutil -lint Apps/iOS/Info.plist
plutil -lint Apps/Watch/Info.plist
plutil -lint WristAssist.xcodeproj/project.pbxproj
```

Run the shared smoke test:

```sh
env SWIFTPM_HOME="$PWD/.build/spm-home" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
  swift run --scratch-path "$PWD/.build" WristAssistSharedSmokeTests
```

After installing full Xcode:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -list -project WristAssist.xcodeproj
swift test --scratch-path "$PWD/.build"
```

Then open `WristAssist.xcodeproj`, set your development team, and build the iOS app with the embedded Watch app.

Current MVP builds the iOS and watchOS schemes separately:

```sh
xcodebuild -project WristAssist.xcodeproj -scheme "WristAssist iOS" -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project WristAssist.xcodeproj -scheme "WristAssist Watch App" -destination "generic/platform=watchOS" CODE_SIGNING_ALLOWED=NO build
```

The watchOS target is a standalone SwiftUI watchOS app linked to the iPhone app by bundle identifiers and WatchConnectivity. App Store-style embedding can be added later by introducing a WatchKit Extension wrapper target.

## Manual MVP Checklist

- Launch iPhone app and save an OpenAI API key.
- Confirm Watch app changes from "Open WristAssist on your iPhone and save API key." to the green microphone and "Click to start" controls after settings sync.
- Quit the iPhone app and confirm the Watch still shows the ready state from its local Keychain copy.
- Clear the API key on iPhone and confirm the Watch clears its local copy and returns to the missing-key message.
- Tap the Watch button, allow microphone access, speak, and hear the model response.
- Tap the button again and confirm capture, playback, and WebSocket stop cleanly.
- Test missing key, invalid key, iPhone unreachable, airplane mode, and denied microphone permission.

## Project Shape

- `Apps/iOS`: iPhone SwiftUI app, Keychain, token minting, WatchConnectivity host.
- `Apps/Watch`: Watch SwiftUI app, Realtime WebSocket client, audio capture/playback.
- `Sources/WristAssistShared`: shared settings, messages, Realtime event models, PCM16 helpers.
- `Tests/WristAssistSharedTests`: shared contract tests for full Xcode/Swift test environments.
- `Tools/WristAssistSharedSmokeTests`: small executable smoke test that avoids XCTest/Testing.
