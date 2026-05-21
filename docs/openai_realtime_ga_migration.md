# OpenAI Realtime — Beta → GA Migration

> **Status:** Shipped 2026-05-21.
>
> **Scope:** Cloud realtime path only. The local LLM path (llama.cpp via `LocalLLMManager`) is unaffected.
>
> **Trigger:** Connecting to the cloud backend started returning
>
> `{"error":{"code":"beta_api_shape_disabled","message":"The Realtime Beta API is no longer supported. Please use /v1/realtime for the GA API."}}` (HTTP 400, ~236-byte JSON body).
>
> **OpenAI docs referenced during the migration:** [Realtime and audio](https://developers.openai.com/api/docs/guides/realtime), [Client secrets](https://developers.openai.com/api/reference/resources/realtime/subresources/client_secrets).

This doc records what was changed so a future reader can:
- See the beta shape next to the GA shape for each item we touched.
- Find the file: line that owns each change.
- Run the same diagnostic we used to identify the migration in the first place.

---

## 1. Summary

| Migration point | Beta (was) | GA (now) | Code |
|---|---|---|---|
| Required header | `OpenAI-Beta: realtime=v1` (never set in this codebase) | _omitted_ | n/a |
| Ephemeral credentials | _none — master key sent directly_ | `POST /v1/realtime/client_secrets` | [OpenAIRealtimeManager.swift](../NeuraLink/Data/DataSources/OpenAI/OpenAIRealtimeManager.swift) `requestEphemeralKey` |
| WebRTC SDP endpoint | `POST /v1/realtime?model=...` with master key + SDP | `POST /v1/realtime/calls` with ephemeral key + SDP | [OpenAIRealtimeManager.swift](../NeuraLink/Data/DataSources/OpenAI/OpenAIRealtimeManager.swift) `postSDPOffer` |
| `session.update` body | flat: `modalities: ["text", "audio"]`, `voice`, `input_audio_transcription`, `turn_detection` | nested under `session.audio.{input,output}`; `session.type = "realtime"` required; `output_modalities` accepts only `["text"]` *or* `["audio"]`; `noise_reduction: { type: "near_field" }` added | [+Handlers.swift](../NeuraLink/Data/DataSources/OpenAI/OpenAIRealtimeManager+Handlers.swift) `sendInitialSessionUpdate` |
| Transcript delta event | `response.audio_transcript.delta` | `response.output_audio_transcript.delta` | [+Handlers.swift](../NeuraLink/Data/DataSources/OpenAI/OpenAIRealtimeManager+Handlers.swift) `handleIncomingJSON` |
| Transcript done event | `response.audio_transcript.done` | `response.output_audio_transcript.done` | same |

---

## 2. Connection flow — full before/after

### Before (beta direct-key flow, broke 2026-05)

```
Client                                    OpenAI
  │
  │  POST /v1/realtime?model=gpt-realtime
  │  Authorization: Bearer <master API key>
  │  Content-Type: application/sdp
  │  Body: <SDP offer>
  │ ───────────────────────────────────────▶
  │
  │           HTTP 200, Content-Type: application/sdp
  │  ◀─────────────────────────────────────
  │           Body: <SDP answer>
```

After the GA rollout this returns `400 beta_api_shape_disabled` instead — the offer is rejected before any audio negotiation happens.

### After (GA two-step handshake)

```
Client                                    OpenAI
  │
  │  POST /v1/realtime/client_secrets
  │  Authorization: Bearer <master API key>
  │  Content-Type: application/json
  │  Body: {"session": {"type": "realtime",
  │                     "model": "gpt-realtime"}}
  │ ───────────────────────────────────────▶
  │
  │           HTTP 200, Content-Type: application/json
  │  ◀─────────────────────────────────────
  │           Body: {"value": "ek_…",
  │                  "expires_at": …,
  │                  "session": {…}}
  │
  │  POST /v1/realtime/calls
  │  Authorization: Bearer <ek_…>     ← ephemeral, ~1 min lifetime
  │  Content-Type: application/sdp
  │  Body: <SDP offer>
  │ ───────────────────────────────────────▶
  │
  │           HTTP 200, Content-Type: application/sdp
  │  ◀─────────────────────────────────────
  │           Body: <SDP answer>
```

Security upside as a side effect: the master API key only ever touches `/client_secrets` over TLS. The WebRTC signaling endpoint sees only the ephemeral token — which is what production deployments must use if they ever ship a client binary.

---

## 3. `session.update` body — full before/after

The body is sent over the WebRTC data channel right after the connection establishes; it tells OpenAI which voice, tools, and turn-detection settings to apply for the rest of the session.

### Before

```json
{
  "type": "session.update",
  "session": {
    "modalities": ["text", "audio"],
    "voice": "alloy",
    "instructions": "...",
    "tools": [...],
    "tool_choice": "auto",
    "input_audio_transcription": { "model": "whisper-1" },
    "turn_detection": { "type": "server_vad" }
  }
}
```

### After

```json
{
  "type": "session.update",
  "session": {
    "type": "realtime",
    "output_modalities": ["audio"],
    "instructions": "...",
    "tools": [...],
    "tool_choice": "auto",
    "audio": {
      "input": {
        "transcription":    { "model": "whisper-1" },
        "turn_detection":   { "type": "server_vad" },
        "noise_reduction":  { "type": "near_field" }
      },
      "output": {
        "voice": "alloy"
      }
    }
  }
}
```

The voice configuration now lives under `session.audio.output`; input-side configuration (`transcription`, `turn_detection`, `noise_reduction`, plus any future `format` knob) lives under `session.audio.input`. `modalities` was renamed `output_modalities` **but the value semantics also changed** — GA accepts only `["text"]` *or* `["audio"]`, not both. The beta shape `["text", "audio"]` is rejected with `invalid_value`. We use `["audio"]`; the transcript still streams over `response.output_audio_transcript.delta` events independently of this setting, so we don't lose the text view.

**`noise_reduction`** values are `"near_field"` (close-talk mics — phone held to mouth, earbuds) or `"far_field"` (room-distance mics — laptop, smart speaker), or omit to disable. We use `near_field` because iPhone conversational use is close-talk. This is server-side and orthogonal to the local LLM path's hardware AEC (VPIO) — `noise_reduction` cleans only the audio that OpenAI receives over WebRTC.

---

## 4. Data-channel event renames

Only the transcript events were renamed in this round. Each old name in the table no longer fires once the GA session is in effect — listening for the beta name silently misses every transcript update.

| Beta name | GA name | Owner case in `handleIncomingJSON` |
|---|---|---|
| `response.audio_transcript.delta` | `response.output_audio_transcript.delta` | streams text deltas into `state.aiTranscript` |
| `response.audio_transcript.done` | `response.output_audio_transcript.done` | sets `transcriptDoneTime` for the speech-timing logic |

Events **not** in the migration list and therefore left on their beta names in code:

- `conversation.item.input_audio_transcription.completed`
- `response.output_item.added`
- `response.function_call_arguments.delta`
- `response.function_call_arguments.done`
- `response.done`

If user transcripts stop arriving, function calling stops working, or response completion stops firing — these are the first suspects. Use the diagnostic in §6 to read the actual names OpenAI is firing.

---

## 5. Audio session — a red herring we initially chased

When the "Answer does NOT contain audio track" warning first appeared, the prime suspect was [LocalLLMManager+Audio.setupAudioEngine](../NeuraLink/Data/DataSources/LocalLLM/LocalLLMManager+Audio.swift) — specifically the `audioEngine.inputNode.setVoiceProcessingEnabled(true)` call added for the local LLM's hardware AEC. The reasoning at the time:

- VPIO replaces the default `RemoteIO` audio unit on the device's mic.
- WebRTC (via `RTCAudioSession`) shares the same hardware and constructs its SDP offer against whichever audio unit is currently active.
- A plausible failure mode was OpenAI's signaling server rejecting the codec set VPIO advertises, stripping the audio m-line from the answer.

We tried gating the voice-processing call on `OpenAISettings.shared.isLocalLLMEnabled` to isolate the two paths. **It made no difference** — the connection still failed with the same 236-byte response. Adding the diagnostic from §6 then surfaced the actual cause (`beta_api_shape_disabled`), which had nothing to do with the audio unit.

The gating was removed once the real fix landed; voice processing is enabled unconditionally again in the current code. WebRTC GA + VPIO coexist without issue on iPhone 11 — the audio m-line is in the offer and OpenAI accepts it.

**Lesson for future debugging:** when WebRTC signaling fails with what looks like an audio-format problem, log the response body before blaming the audio session. The bug was in a JSON error string, not a codec list.

---

## 6. Diagnostic — how we identified the migration in one round

[OpenAIRealtimeManager.postSDPOffer](../NeuraLink/Data/DataSources/OpenAI/OpenAIRealtimeManager.swift) used to silently hand whatever bytes OpenAI returned to `RTCSessionDescription(type: .answer, sdp: ...)`, which then failed deep inside WebRTC with a generic "Failed to set remote desc" message. The actual server error was thrown away.

We now log:

- HTTP status code
- `Content-Type` header
- The body preview (first 500 chars at warning level; first 120 surfaced into the UI state error)

If the body doesn't start with `v=0\r\n` (the SDP version line) we bail before WebRTC ever sees it. That's how `beta_api_shape_disabled` surfaced clearly enough to read.

Same pattern in `requestEphemeralKey` for the step-1 call — failure modes there look like:

```
[AI]: client_secrets failed (status=401): {"error":{"message":"Incorrect API key…"}}
[AI]: client_secrets failed (status=404): {"error":{"message":"Model not found: …"}}
```

Every event arriving on the data channel is logged via `[AI Event Received]: <type>` in `dataChannel(_:didReceiveMessageWith:)`. Future event renames are visible here without any extra instrumentation — grep for `[AI Event Received]` in the device console and any name the code doesn't handle yet will appear unanswered.

---

## 7. References

- [Beta to GA migration guide](https://developers.openai.com/api/docs/guides/realtime) — the source for §1–§4.
- [Client secrets reference](https://developers.openai.com/api/reference/resources/realtime/subresources/client_secrets) — response shape used by `requestEphemeralKey` (top-level `value`, plus `expires_at` and `session`).

---

## 8. Future work flagged from the docs

Items the OpenAI docs mention. Updated 2026-05-21 — the `noise_reduction` entry from the first revision of this doc landed; one entry was wrong about scope and is corrected here.

### Shipped after first publication of this doc

- **`session.audio.input.noise_reduction`** — added with value `{"type": "near_field"}`. *(The first revision of §8 said this was "not directly applicable to the cloud path because that path doesn't go through VPIO" — that was wrong. `noise_reduction` is a server-side setting that cleans the user's WebRTC audio before OpenAI processes it, and is therefore exactly applicable to the cloud path. VPIO is the local LLM's hardware AEC and runs in a different process before any audio leaves the device — orthogonal concern.)*

- **`output_modalities` value corrected to `["audio"]`.** First revision sent `["audio", "text"]` (matching the beta `modalities` array's two-value form). GA rejects this with `invalid_value` at `session.output_modalities`, message: *"Invalid modalities: ['audio', 'text']. Supported combinations are: ['text'] and ['audio']."* The error event was silently dropped before we added the `case "error":` handler in [+Handlers.swift](../NeuraLink/Data/DataSources/OpenAI/OpenAIRealtimeManager+Handlers.swift), which caused the entire session.update to be ignored and the model fell back to defaults — symptoms were "model speaks English instead of Japanese" and "user context isn't applied" because none of our persona/context instructions ever landed. Discovered on first device test after the diagnostic was added; one-line fix. Transcript events fire the same way under `["audio"]` so we don't lose anything.

- **`error` event handler + `session.created`/`session.updated` echo.** Added as diagnostics (§6) but became load-bearing once they surfaced the `output_modalities` issue above. Worth keeping permanently — future OpenAI schema changes that reject our session.update will now fail loudly with the exact `param` and `message` from the server.

### Still pending — actionable when triggered

1. **Migrate the remaining beta-named events** if/when they stop firing. Candidates are listed at the end of §4. The pattern observed in this round is `response.<x>.{delta,done}` → `response.output_<x>.{delta,done}`, so a future rename most likely follows the same shape. The `[AI Event Received]: <type>` log line in `dataChannel(_:didReceiveMessageWith:)` surfaces any unhandled name on the next test run.
2. **`session.audio.input.format` / `session.audio.output.format`** — the GA shape exposes per-direction format config. Docs only confirm "PCM, 24 kHz" as the supported set; the exact JSON shape for the format value isn't published in the page we could reach. Currently we let OpenAI pick defaults; revisit if we ever need a specific sample rate or codec for compatibility with another sink.
3. **Pin the model identifier.** Currently we use the unversioned alias `gpt-realtime`. A dated identifier would protect against silent behavior changes when OpenAI promotes a new build to the alias, but no dated GA version is enumerated in the docs page we can read. Worth pinning once a date appears.
