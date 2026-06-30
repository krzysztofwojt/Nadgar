# Nadgar

Nadgar is a native SwiftUI iPhone + Apple Watch MVP for push-to-talk text chat with OpenAI from Apple Watch.

## What Is Implemented

- iPhone app for provider settings and OpenAI API key storage in Keychain.
- Apple Watch app with a standalone push-to-talk chat UI.
- WatchConnectivity bridge where iPhone syncs settings and separately syncs/deletes the OpenAI API key on the paired Watch.
- iPhone-side API-key validation against the configured assistant model.
- Watch-side API key storage in Keychain and direct HTTPS calls to transcription plus Responses APIs.
- Responses requests can use OpenAI web search, preserve source citations, and hand source URLs off from Watch to iPhone.
- Watch push-to-talk recording to temporary 24 kHz mono WAV files.
- In-memory Watch chat session that resets on app process restart or API-key reset.
- Shared Swift package target for settings, WatchConnectivity messages, OpenAI request models, WAV construction, legacy Realtime event models, and PCM16 conversion.
- Unit test files for shared contracts, plus a framework-free smoke-test executable for environments without full Xcode.

## Auth Model

The functional MVP path is bring-your-own OpenAI Platform API key.

The raw API key is stored on iPhone in Keychain and synced to the paired Watch, where it is also stored in Keychain. This lets the Watch transcribe audio and request assistant text without an active iPhone connection after the key has synced once.

The ChatGPT/Codex option is shown in the iPhone UI but disabled. Codex OAuth/access tokens are scoped to Codex workflows, not general OpenAI API calls.

## Website

The public Nadgar website lives in `site/` and is deployed to GitHub Pages by `.github/workflows/pages.yml`.

- Production domain: `https://nadgar.app/`
- App Store privacy URL: `https://nadgar.app/#privacy`
- FAQ: `https://nadgar.app/#faq`

## Requirements

- Full Xcode with iOS 18 and watchOS 11 SDKs.
- A physical Apple Watch is recommended for the first end-to-end audio test.
- An OpenAI Platform API key with access to `gpt-5.5` and `gpt-4o-mini-transcribe`.

This workspace was initially created on a machine with Command Line Tools only, so full app build verification must be run after Xcode is installed and selected.

## Verify

Validate plist and project syntax:

```sh
plutil -lint Apps/iOS/Info.plist
plutil -lint Apps/Watch/Info.plist
plutil -lint Nadgar.xcodeproj/project.pbxproj
```

Run the shared smoke test:

```sh
env SWIFTPM_HOME="$PWD/.build/spm-home" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
  swift run --scratch-path "$PWD/.build" NadgarSharedSmokeTests
```

After installing full Xcode:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -list -project Nadgar.xcodeproj
swift test --scratch-path "$PWD/.build"
```

Then open `Nadgar.xcodeproj`, set your development team, and build the iOS app with the embedded Watch app.

Current MVP builds the iOS and watchOS schemes separately:

```sh
xcodebuild -project Nadgar.xcodeproj -scheme "Nadgar iOS" -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Nadgar.xcodeproj -scheme "Nadgar Watch App" -destination "generic/platform=watchOS" CODE_SIGNING_ALLOWED=NO build
```

The watchOS target is a standalone SwiftUI watchOS app linked to the iPhone app by bundle identifiers and WatchConnectivity. App Store-style embedding can be added later by introducing a WatchKit Extension wrapper target.

### Mock OpenAI Watch Run

For local Watch UI testing without spending OpenAI tokens, run the `Nadgar Watch App` scheme in Debug with either:

- launch argument `-NadgarMockOpenAI`
- environment variable `NADGAR_MOCK_OPENAI=1`

This mode still records through the microphone and writes the temporary WAV file, but it skips the transcription and Responses network requests. The Watch treats the API key as present and appends deterministic mock user and assistant chat bubbles after short simulated delays. The flag is ignored in Release builds.

For Simulator-only citation rendering checks, run the shared `Nadgar Watch Mock Citations` scheme. It enables mock OpenAI plus `-NadgarMockCitationChat`, so the Watch starts with a seeded assistant bubble containing bold, italic, inline code, markdown links, and `url_citation` ranges. The same citation-rich mock response is used for subsequent mock PTT turns. You can also enable this fixture manually with:

- launch argument `-NadgarMockCitationChat`
- environment variable `NADGAR_MOCK_CITATION_CHAT=1`

## Manual MVP Checklist

- Launch iPhone app and save an OpenAI API key.
- Confirm Watch app changes from "Open Nadgar on your iPhone and save API key." to the black chat screen with the green microphone after settings sync.
- Quit the iPhone app and confirm the Watch still shows the ready state from its local Keychain copy.
- Clear the API key on iPhone and confirm the Watch clears its local copy and returns to the missing-key message.
- Hold the Watch microphone, allow microphone access, speak, release, and confirm the transcript plus assistant text bubbles appear.
- Scroll the chat with finger or Digital Crown, then relaunch the Watch app and confirm it starts a fresh empty session.
- Test missing key, invalid key, iPhone unreachable, airplane mode, and denied microphone permission.

## Project Shape

- `Apps/iOS`: iPhone SwiftUI app, Keychain, API-key validation, WatchConnectivity host.
- `Apps/Watch`: Watch SwiftUI app, push-to-talk recorder, transcription client, Responses client, chat view model.
- `Sources/NadgarShared`: shared settings, messages, OpenAI request models, WAV/PCM16 helpers, and legacy Realtime event models.
- `Tests/NadgarSharedTests`: shared contract tests for full Xcode/Swift test environments.
- `Tools/NadgarSharedSmokeTests`: small executable smoke test that avoids XCTest/Testing.
- `site`: static GitHub Pages website for the Nadgar landing page, privacy policy, and FAQ.
