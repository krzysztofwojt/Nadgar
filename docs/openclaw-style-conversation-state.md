# Continuous Conversation Session Plan

This note records the intended conversation-state direction for Nadgar.
The product goal is a single messenger-style thread, not a ChatGPT-style list
of separate chats.

## Product Goal

WristAssist should feel like one ongoing assistant conversation:

- opening the Watch app shows the newest messages at the bottom;
- scrolling upward reveals recent prior messages;
- the user does not choose between chat threads;
- model context can reset or compact without changing the visible thread;
- the Watch never tries to render an unbounded lifetime transcript.

The user-facing conversation and the model context must be separate systems.
The visible thread is local UI history. The model context is the smaller state
sent to, or referenced by, OpenAI.

## Current State

## Nadgar State Model

For Nadgar, keep the model simpler than OpenClaw while preserving the same
core separation between visible local history, local recovery data, remote
provider chain state, and compacted human-readable fallback context.

## Patterns To Reuse

### OpenClaw

OpenClaw separates the stable conversation route from the active model run:

- `sessionKey` identifies the durable conversation bucket, such as a direct
  message, group, channel, cron job, or webhook.
- `sessionId` identifies the current model context/transcript for that bucket.

Commands such as `/new` or `/reset` create a fresh model session while the same
message route continues. OpenClaw also treats compaction as a context operation:
the user stays in the same conversation while the runtime compacts or rotates
the active model thread.

For WristAssist, the useful part is this split:

- `conversationKey = "default"` for the single visible assistant thread.
- `contextEpochId` or `currentSessionId` for the current model-context chain.

### Hermes Agent

Hermes persists session metadata and full message history in SQLite, with FTS5
search, source tags, parent/child session links, and compression state. Two
details are especially useful for WristAssist:

- Compression does not destroy history. Hermes can soft-archive older rows and
  keep compacted history discoverable while the active context loads only the
  compacted/live rows.
- Compression continuations can be projected forward so the user sees one
  logical conversation even when the storage/model layer has multiple linked
  segments.

For WristAssist, we do not need a session picker, but the `active` versus
`compacted` idea maps well to a watch-sized transcript.

### OpenAI APIs

OpenAI now offers three relevant state patterns:

- Responses API with `previous_response_id`, where the app sends only the new
  turn and keeps a previous response pointer.
- Conversations API, where a durable `conversation` id can be reused across
  sessions/devices/jobs and can store conversation items.
- Stateless Responses with local history and/or OpenAI compaction, using
  `store=false`, `include=["reasoning.encrypted_content"]`, and compacted
  output items when needed.

The important constraint: the Watch still needs local UI history. OpenAI state
can help model continuity, but it should not be the only source of truth for
what the Watch renders.

## Proposed Data Model

Add a small local conversation store on Watch:

```swift
struct ConversationRecord: Codable, Sendable {
    var conversationKey: String // "default"
    var schemaVersion: Int
    var activeProviderID: String // "openai" in V1
    var contextEpochID: UUID
    var providerContexts: [String: ProviderContextState]
    var humanSummary: String?
    var summaryThroughMessageId: UUID?
    var summaryContextEpochID: UUID?
    var events: [ConversationEvent]
    var messages: [ChatMessage]
}

struct ChatMessage: Codable, Sendable {
    var contextEpochID: UUID?
}

struct ProviderContextState: Codable, Sendable {
    var providerID: String
    var contextID: String?
    var parentContextID: String?
    var lastRemoteTurnID: String?
    var metadata: [String: String]
}
```

Suggested storage:

- V1: JSON file in the Watch app container, written atomically after each turn.
- Later: SQLite if we need search, large history, or iPhone/Watch sync merging.

JSON is enough for a single-thread Watch MVP and avoids introducing SQLite
complexity before we need it.

## Model Context Strategy

Default recommendation for WristAssist V1: use OpenAI `previous_response_id`
behind a provider adapter. The Watch view model owns the visible conversation;
the OpenAI adapter owns the Responses chain pointer. This keeps the shape ready
for a later Hermes provider, where the provider context can be a Hermes session
or continuation handle instead of an OpenAI response id.

Normal request:

- `store=true`;
- `previous_response_id = providerContexts["openai"].lastRemoteTurnID`;
- `input = [new user message]`;
- `context_management = [{"type":"compaction","compact_threshold":64000}]`.

Bootstrap/fallback request:

- no `previous_response_id`;
- `store=true`;
- `input = humanSummary + budget-selected raw recovery tail + current user message`;
- save the returned response `id` into the OpenAI provider context.
- use only `humanSummary` and raw messages tagged with the active
  `contextEpochID`, so fallback does not mix context across model resets.

Local storage thresholds:

- render the latest 40 messages on Watch;
- keep up to 80 full local messages as a raw recovery buffer;
- fallback context is selected by an approximate token budget, not by a fixed
  message count;
- when local full history exceeds 80 messages, update `humanSummary` with a
  best-effort `store=false` summary request and prune summarized messages from
  the active `contextEpochID`.

The Watch still keeps local UI history because provider state is not the source
of truth for rendering. `humanSummary` is not sent in the normal chained OpenAI
path; it is used when bootstrapping a fresh chain or recovering from a rejected
provider context handle.

## Watch UI Rendering Strategy

The Watch should not load the entire lifetime transcript into SwiftUI.

Recommended V1 behavior:

- Load the newest display window from local storage, for example 40 messages.
- Render with the existing `ScrollView` + `LazyVStack`.
- Auto-scroll to bottom only when a new local turn is appended or when the user
  is already near the bottom.
- If there are older stored messages, show a top marker:
  `Start of available history`.
- If the oldest visible message is already compacted, show:
  `Start of available history`.

Do not implement full infinite scroll on the Watch in the first pass. It adds
state and memory pressure without being central to the assistant experience.
The iPhone app can later expose full history, export, search, or reset.

## Time And Date Labels

Use `createdAt` from each message.

Display rules:

- user bubble: show a small timestamp above the bubble;
- today: show only time, e.g. `14:37`;
- yesterday: insert a day divider `Yesterday` above the first message from that
  day, then show times over user bubbles;
- day before yesterday: divider `Day before yesterday`;
- older: divider with localized date, e.g. `21 czerwca` in Polish locale;
- if locale is not Polish, use the device locale instead of hard-coded Polish.

Implementation shape:

- precompute `ChatTimelineItem` in the view model, not inside `body`;
- use explicit item identity for day dividers, context markers, and messages;
- keep formatting in a small `ChatTimelineFormatter` helper so tests can cover
  today/yesterday/day-before/older cases with a fixed calendar.

## Reset Semantics

The UI should avoid a visible list of chats, but we still need reset semantics:

- API-key change or deletion rotates the active provider context epoch;
- visible thread stays local and shows a `Context reset` marker;
- model context resets independently of `conversationKey = "default"`;
- local stored messages should not be deleted unless the user chooses a
  destructive clear-history action.

The destructive clear action is exposed from iPhone settings as
`Clear Conversation History` and removes local Watch messages, `humanSummary`,
provider context, and reset events.

## Implementation Plan

1. Introduce local persistence.
   Add a `WatchConversationStore` that loads/saves `ConversationRecord` and a
   bounded message array for `conversationKey = "default"`. Start with JSON and
   atomic writes.

2. Separate UI history from model input.
   Keep `WatchVoiceViewModel.messages` as the display window. In the normal
   OpenAI path, the provider adapter sends only `previous_response_id + current
   transcript`. In fallback, the adapter sends `humanSummary + newest full
   local messages that fit the recovery budget + current user message`.

3. Persist each turn.
   On transcription success, persist the user message. On assistant success,
   persist the assistant message and provider context returned by the active
   provider. Persist failed placeholders only if we want failure history to
   survive relaunch.

4. Add compaction.
   Enable OpenAI server-side compaction for chained Responses requests. When
   local full history crosses 80 messages, update `humanSummary` with a
   best-effort `store=false` summary request and prune older full messages.

5. Add timeline rendering.
   Replace direct `ForEach(viewModel.messages)` with `ForEach(viewModel.timelineItems)`.
   Add day dividers, user-bubble timestamps, and context markers.

6. Add retention safeguards.
   Load only the newest display window on Watch. Keep a hard cap for JSON size;
   if exceeded, compact older messages or prune fully obsolete placeholder/error
   rows first.

7. Preserve reset behavior.
   API-key changes rotate only the active provider context and add a persisted
   context-reset event; only `Clear Conversation History` deletes local
   messages.

## Verification Plan

- Unit-test `ChatTimelineFormatter` with fixed dates.
- Unit-test `WatchConversationStore` encode/decode and migration from missing
  file to empty conversation.
- Unit-test provider context migration and OpenAI request construction so old
  messages are not sent on the normal chained path.
- Run the existing shared smoke test.
- Build both iOS and Watch schemes when Xcode is available.
- In mock OpenAI Watch mode, verify that relaunch restores recent messages and
  that the top marker appears once older context is compacted.

## Decisions

- Use `previous_response_id` as the default active OpenAI chain.
- Keep Watch history bounded and local; do not implement infinite scroll in V1.
- Preserve local history on API-key changes.
- Keep `humanSummary` internal and use it only as fallback/bootstrap context.
