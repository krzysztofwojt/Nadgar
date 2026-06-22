# watchOS Direct Realtime WebSocket Spike

Date: 2026-06-22

This note records the result of the WristAssist experiment that tested whether
the Apple Watch app can connect directly to the OpenAI Realtime API over a
WebSocket after starting a real watchOS audio session.

## Goal

Determine whether `URLSessionWebSocketTask` can be used directly from the
watchOS app when WristAssist is actively using audio for its real product flow:

1. Capture microphone input on Apple Watch.
2. Stream audio to an AI model.
3. Play back the assistant audio response on Apple Watch.

The motivation was Apple's watchOS networking guidance: low-level networking is
restricted on watchOS, but Apple documents exceptions for active audio streaming
and a few other cases.

## Spike Setup

The spike was implemented in an isolated worktree on branch:

```text
wristassist/direct-realtime-audio-session-spike
```

The main changes were:

- Enabled watch background audio with `UIBackgroundModes = audio`.
- Started `AVAudioSession` before opening the WebSocket:
  - category: `.playAndRecord`
  - mode: `.voiceChat`
  - `setActive(true)`
- Started a real `AVAudioEngine` graph before WebSocket connect.
- Switched physical-watch capture diagnostics from `inputNode.installTap` to
  `AVAudioSinkNode`, because the tap path did not produce buffers on the
  physical watch while the sink node did.
- Waited for a real pre-connect input audio chunk before calling
  `URLSessionWebSocketTask.resume()`.
- Added URLSession delegate diagnostics for:
  - `waitingForConnectivity`
  - WebSocket `didOpen`
  - WebSocket `didClose`
  - task completion errors
- Added an explicit final test with:
  - `URLSessionConfiguration.networkServiceType = .avStreaming`
  - `URLRequest.networkServiceType = .avStreaming`

## Physical Watch Evidence

The important result is that audio was active before the WebSocket connect
attempt. The physical watch produced diagnostics like:

```text
session sr=48000 in=3 out=1 micbi->spk
voiceproc ok agc=true output fmt sr=24000 ch=1
input in fmt sr=48000 ch=1
input out fmt sr=48000 ch=1
input sink connected
engine running true
sink pull 1 frames=1104
raw sink 1 frames=1104
input chunk ms=22 rms=0.000
preconnect chunk 1
audio ready
waiting first input
input ready before ws
connect start auto
ws net service avStreaming
websocket task resume
URLSession waitingForConnectivity
```

The input chunk and continuing `preconnect chunk` diagnostics confirmed that the
app had a real running audio engine and was receiving audio buffers before the
WebSocket attempt.

The WebSocket still did not open. The physical-watch run remained in
`waitingForConnectivity` and eventually failed:

```text
URLSession error NSURLErrorDomain#-1001
connect failed NSURLErrorDomain#-999
failed NSURLErrorDomain#-999
```

The meaningful error is `NSURLErrorDomain#-1001` after
`waitingForConnectivity`. The later `-999` is most likely cancellation/cleanup
after the timeout path.

An earlier physical-watch run also showed that plain HTTPS could reach OpenAI
while the WebSocket path was blocked. System logs included an NECP denial for
the WebSocket path:

```text
Path was denied by NECP policy
```

## Simulator Evidence

The simulator was useful only for validating local ordering. It showed the
expected flow:

```text
start auto
starting audio
audio ready
waiting first input
preconnect chunk 1
input ready before ws
connect start auto
websocket task resume
```

This did not settle the production question, because the watchOS simulator does
not reproduce the physical watch networking policy behavior.

## Conclusion

Direct watchOS-to-OpenAI Realtime WebSocket is not a viable production
architecture for WristAssist based on this experiment.

High-confidence findings:

- WristAssist can start a real watchOS audio session before the WebSocket.
- The physical watch can run an audio engine and deliver input buffers before
  the WebSocket attempt.
- Adding `.avStreaming` to both `URLSessionConfiguration` and `URLRequest` did
  not unblock the connection.
- The failure happens before any Realtime protocol exchange. This is not caused
  by session JSON, PCM formatting, base64 encoding, model selection, or Realtime
  event handling.
- Plain HTTPS reachability is not proof that the direct WebSocket path works on
  watchOS.

The practical interpretation is that watchOS still treats this direct WebSocket
as disallowed or unavailable for this app's runtime state, even when the app is
legitimately recording audio for the assistant flow.

## Remaining Diagnostic Idea

One possible final diagnostic is to test an active playback-oriented audio
session:

- keep `.playAndRecord` if microphone input is still needed;
- start real, non-silent playback before opening the WebSocket;
- optionally test with an `AVPlayer`/HTTP audio stream to approximate Apple's
  documented streaming-audio scenario.

If the WebSocket opens only while real playback is already active, that would
suggest Apple's exception is closer to playback streaming than microphone
capture. It should still be treated as diagnostic evidence, not as a production
workaround. Fake playback to unlock networking would be fragile and likely risky
for App Review.

## Recommended Direction

Use one of these architectures instead of direct watchOS Realtime WebSocket:

1. iPhone relay for live speech-to-speech.
   - Apple Watch handles UI, microphone, and speaker.
   - iPhone owns the OpenAI Realtime session.
   - Watch sends framed audio chunks to iPhone and receives output audio/events.
   - This is the best fit for low-latency conversational UX.

2. HTTPS request-based watch flow as a reliable fallback.
   - Watch records a bounded utterance.
   - Watch sends it over normal HTTPS.
   - Server or API returns text/audio.
   - This is less live, but much more aligned with watchOS networking behavior.

The existing PTT/HTTPS path should remain available as the independent-watch
fallback even if an iPhone relay is implemented later.

## References

- Apple: [TN3135: Low-level networking on watchOS](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)
- Apple: [Streaming Audio on watchOS 6](https://developer.apple.com/videos/play/wwdc2019/716/)
- OpenAI: [Realtime API with WebSocket](https://developers.openai.com/api/docs/guides/realtime-websocket)
