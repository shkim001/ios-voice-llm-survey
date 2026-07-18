# Offline-First Interview Specification

Status: implemented through final integration review; physical-device and deployed-server field validation remains

Date: 2026-07-17

## 1. Purpose and invariant

This specification defines how the iOS field-survey app will tolerate missing GPS, unavailable internet, interrupted processing, and server failures without losing an interview.

The core invariant is:

> The original `.m4a` interview recording must be saved locally before transcription, AI analysis, cloud-session creation, or upload is attempted. It must never be automatically deleted merely because GPS, transcription, LLM analysis, networking, or server upload failed.

An unuploaded interview may be deleted only through an explicit, user-confirmed destructive action. Automatic retention cleanup must never delete an unuploaded interview.

The design is offline-first rather than offline-only. Local durable files are authoritative for recovery. Network services enhance and synchronize an interview, but they do not determine whether the interview can be recorded or retained.

## 2. Audited current architecture

### 2.1 Main iOS components

- `CounterApp/ViewController.swift` orchestrates questionnaire selection, respondent intake, GPS-gated recording, review, Apple Speech transcription, LLM analysis, clarification, local package writing, upload, reset, retry entry points, and retention calls.
- `CounterApp/TrajectoryTracker.swift` captures the required recording-start location and samples the latest location about every 15 seconds while recording.
- `CounterApp/SessionManager.swift` creates `Documents/SurveySessions/<local-session-id>/`, allocates recording URLs, removes empty folders, and performs age/count-based retention.
- `CounterApp/LLMService.swift` sends transcripts to OpenAI, Gemini, or a custom OpenAI-compatible service and parses matched-question JSON.
- `CounterApp/SurveyAPIClient.swift` creates cloud sessions, fetches questionnaires, uploads packages, and reads dashboard data.
- `CounterApp/DeferredSessionOutbox.swift` is the Phase 4 folder-scanning retry service. It replaced the unreferenced legacy `PendingSurveyUploadStore.swift` answer-row queue.
- `CounterApp/PendingTrajectoryStore.swift` defines persisted trajectory points and a legacy trajectory queue.
- `CounterApp/QuestionnaireModels.swift` defines questionnaire, respondent, matched-answer, and exported-package compatibility models. `QuestionnaireStore` loads the bundled questionnaire before considering the cache.
- `CounterApp/MapViewController.swift` displays device location with MapKit and can pass a GPS coordinate into the survey screen. It does not currently search for an address or place.
- `CounterApp/LocalSessionDashboardViewController.swift` loads local manifests and finalized/cached-server packages, shows recoverable unfinished recordings, and provides a scoped Retry Now action for eligible local sessions.
- `CounterApp/AudioFilesViewController.swift` discovers `.m4a` files independently of `session.json` and supports playback, sharing, and confirmed deletion.
- `CounterApp/Info.plist` and Xcode build settings contain the existing microphone, Speech, and location permissions and background-location declaration.

### 2.2 Backend components

- `server/app/main.py` creates survey sessions and receives `session.json` plus optional audio at `POST /sessions/{session_id}/package`.
- The uploaded package is stored below `SURVEY_PACKAGE_STORAGE_DIR/<cloud-session-id>/`; MySQL stores an index in `session_packages` and derived rows in `analysis_answers`.
- `server/schema.sql` permits null `gps_lat`, `gps_lon`, and `location_label` in `session_packages`, so a package without device GPS is already structurally possible.
- Existing package parsing treats `recording_start_trajectory_point` as GPS. Place-search coordinates must therefore be represented separately so they are not misidentified as device GPS.

### 2.3 Test and project configuration

- `CounterAppTests/CounterAppTests.swift` and the UI test targets currently contain only generated placeholder tests.
- The app uses Swift 5, targets iOS 18.5, and is built through the file-system-synchronized Xcode project groups.
- No third-party mapping or connectivity dependency is present. MapKit, Core Location, Speech, and Network framework APIs are available to the target.
- A baseline simulator build was attempted with full Xcode. The build reached Swift compilation setup but failed while compiling storyboards/assets because the local iOS 26.5 simulator platform/runtime service was unavailable. This is an environment limitation, not a diagnosed source-code failure.

## 3. Current end-to-end workflow

### 3.1 Launch and preparation

1. `ViewController.viewDidLoad()` calls `loadQuestionnaire()`, requests Speech and microphone permission, configures the UI, invokes local cleanup, and calls the currently empty package retry hook.
2. `loadQuestionnaire()` first loads bundled `questionnaire.json`. It then selects a cached questionnaire if available and asynchronously refreshes published questionnaires when the Survey API is configured.
3. `initializeSessionAndPurge()` calls `purgeEmptySessions()` and `purgeOldSessions(keepLast: 50, maxAgeDays: 7)`.

### 3.2 Interview identity and cloud setup

1. Starting an interview requires a saved interviewer profile.
2. The interviewer chooses a questionnaire and submits respondent information.
3. Respondent information is retained in `ViewController` memory.
4. A best-effort `ensureCloudSessionCreated()` task begins immediately, before recording. A failure is logged but is not persisted as retryable state.

### 3.3 GPS and recording

1. `prepareAndStartRecording()` calls `TrajectoryTracker.captureRequiredRecordingStartPoint()`.
2. The one-shot requester distinguishes some internal errors—permission denied, unavailable, and timeout—but the UI collapses all failures into one generic GPS-unavailable message.
3. A location is considered usable when its coordinate is valid, horizontal accuracy is nonnegative, and it is no more than 60 seconds old. There is no low-accuracy threshold or typed low-accuracy result.
4. Any GPS failure prevents recording.
5. After GPS succeeds, `startRecording(with:)` lazily creates the local session folder and recording URL.
6. Recording metadata is written to a sidecar JSON before `AVAudioRecorder.record()` is called. The sidecar includes respondent information and the recording-start point, but does not freeze the full interviewer and questionnaire snapshot or processing states.
7. `AVAudioRecorder` writes the `.m4a` directly into the session folder. `TrajectoryTracker` samples locations while recording.

### 3.4 Stop, review, and deletion

1. Stopping calls `AVAudioRecorder.stop()`, ends trajectory tracking, and updates the recording sidecar.
2. The review popup offers playback, Analyze Answers, or Discard Recording.
3. Discard requires confirmation and removes the current `.m4a` plus its recording sidecar. This is an allowed explicit deletion path.

### 3.5 Transcription, analysis, and clarification

1. Analyze Answers calls `transcribeAudio(url:)` with `SFSpeechURLRecognitionRequest`.
2. The current code checks `recognizer.isAvailable`, but does not inspect `supportsOnDeviceRecognition` and does not set `requiresOnDeviceRecognition`.
3. The installed Speech SDK states that offline operation is only supported when `supportsOnDeviceRecognition` is true; `requiresOnDeviceRecognition` is honored only in that case.
4. A successful transcript is assigned only to the in-memory `transcription` property.
5. The transcript is not written to disk before `LLMService.analyzeTranscription()` starts.
6. Transcription or LLM failure re-enables Analyze, but does not persist the transcript, error, retry count, or next processing stage.
7. Successful LLM matches may enter a sequence of clarification prompts. Clarification progress is also in memory.

### 3.6 Package creation, upload, and reset

1. After clarification, `finalizeLLMResults()` writes `session.json` atomically in the local session folder.
2. It then calls `uploadSessionPackageToCloud()`.
3. If needed, that method tries cloud-session creation again and uploads `session.json` plus the `.m4a`.
4. Upload failure is logged only. No package retry record is created.
5. Whether upload succeeds or fails, the normal completion path resets the active participant after the upload attempt returns.
6. The local finalized package and audio normally survive that reset, but the app has no durable indication of the failed upload or automatic package retry.

### 3.7 Retry, retention, dashboard, and deletion

- At the audited baseline, `flushPendingSurveyUploads()` did nothing for package storage and `PendingSurveyUploadStore` did not provide whole-session recovery. Phase 4 replaces that gap with manifest scanning; `PendingTrajectoryStore` remains separate compatibility state for the trajectory endpoint.
- `purgeOldSessions()` removes folders older than seven days once they fall outside the newest 50. It does not test upload status and can therefore delete an unuploaded recording or package.
- `purgeEmptySessions()` safely retains a folder containing either `.m4a` or `session.json`, but it does not know about the proposed draft state.
- The dashboard only discovers folders containing valid `session.json`; unfinished recordings remain visible only through Audio Files.
- Audio Files and Dashboard both provide confirmed deletion. Dashboard deletion removes an entire local session folder, including unuploaded audio; its warning identifies local-only data but should become more explicit about deleting the only copy.

## 4. Confirmed failure points

1. GPS is a hard prerequisite for recording instead of an independent state.
2. The recoverable interview identity is incomplete until final package creation.
3. A transcript can be lost after Speech succeeds but before `session.json` is written.
4. Clarification progress can be lost if the app terminates.
5. Network work starts before the local recording exists.
6. Cloud-session and package-upload failures are not represented by a durable retry queue.
7. A lost response from cloud-session creation can cause a later retry to create a duplicate respondent/session.
8. Network reachability and service reachability are not modeled separately.
9. Current Speech behavior may silently depend on the network.
10. Automatic retention can remove unuploaded interviews.
11. The dashboard cannot guide recovery of unfinished work.

## 5. Required operating cases

The four cases below are outcomes of independent location, transcription, analysis, and upload states. They must not be implemented as four duplicated pipelines.

### 5.1 Internet available, GPS available

1. Capture a fresh, sufficiently accurate GPS start point.
2. Create the local session and draft, record audio, and confirm the `.m4a` is nonempty/readable.
3. Atomically mark the audio as recorded locally.
4. Transcribe and atomically save `transcript.txt` before any LLM request.
5. Analyze, persist results, resolve and persist clarification, and create `session.json`.
6. Create or recover the idempotent cloud session and upload the package.
7. Any failure after step 3 leaves a dashboard-visible recoverable local session.

### 5.2 Internet unavailable, GPS available

1. Capture GPS and record normally.
2. Save audio, draft metadata, and trajectory locally.
3. If on-device Speech is supported, set `requiresOnDeviceRecognition = true`, attempt transcription, and save a successful transcript immediately.
4. If on-device Speech is unsupported or fails, leave transcription pending.
5. Defer network-dependent Speech, LLM analysis, cloud-session creation, and upload.
6. Offer Try Again and Finish and Process Later. The audio and draft are already safe before either choice appears.

### 5.3 Internet available, GPS unavailable

Present four actions:

1. **Try GPS Again** — rerun the typed location request.
2. **Record Without GPS** — record with null coordinates and the exact failure status.
3. **Search for an Address or Place** — use MapKit search and save the selected place separately from GPS.
4. **Cancel Interview** — cancel before audio recording begins; remove only an empty/preparing session draft.

After recording starts, transcription, analysis, local package creation, and upload proceed normally regardless of the chosen location source.

### 5.4 Internet unavailable, GPS unavailable

1. Allow Record Without GPS.
2. Save the `.m4a`, respondent, frozen interviewer, frozen questionnaire, checked choices, and exact missing-location state.
3. Attempt only explicitly supported on-device transcription.
4. Defer remaining work and expose the draft in Dashboard.
5. Resume processing when manually requested or when a later foreground connectivity hint permits another attempt.

## 6. Persistent state model

### 6.1 Status values

`audio_status`:

- `preparing`
- `recording`
- `recorded_locally`
- `failed`

`location_status`:

- `pending`
- `acquiring`
- `available`
- `permission_denied`
- `timed_out`
- `low_accuracy`
- `unavailable`

`location_source`:

- `device_gps`
- `place_search`
- `none`

`transcription_status`:

- `pending`
- `in_progress`
- `completed`
- `failed`
- `pending_retry`

`analysis_status`:

- `pending`
- `in_progress`
- `completed`
- `failed`
- `pending_retry`

`clarification_status`:

- `not_required`
- `pending`
- `completed`

`upload_status`:

- `not_ready`
- `pending`
- `in_progress`
- `uploaded`
- `failed`

Shared retry metadata:

- `retry_count`
- `last_error`
- `last_attempt_at`
- `next_retry_at`

All enums must decode unknown future values safely into a conservative pending/failed representation rather than making an interview unreadable.

### 6.2 Derived lifecycle

The UI derives one lifecycle label from independent states:

```text
recording
  -> recorded_locally
  -> needs_transcription
  -> needs_analysis
  -> needs_clarification
  -> ready_to_upload
  -> uploaded
```

The lifecycle is not a replacement for the independent fields. For example, `location_status = permission_denied` may coexist with `analysis_status = completed` and `upload_status = uploaded`.

### 6.3 Draft contents

`session_state.json` will contain:

- schema version and local session UUID;
- created/updated timestamps;
- frozen respondent information;
- frozen interviewer profile rather than a live reference to the current profile;
- frozen questionnaire identity, hash, title, version, and full question/options snapshot;
- recording filename, recorded time, size, and audio status;
- location status, source, error detail, optional device-GPS start point, optional trajectory, and optional selected-place snapshot;
- interviewer-checked option codes;
- optional transcript filename and transcription status;
- optional matched questions plus analysis and clarification state;
- optional cloud respondent/session identifiers;
- upload state and retry metadata.

Secrets, API keys, and base URLs must never be copied into a session draft.

## 7. Local file layout and write ordering

```text
Documents/
└── SurveySessions/
    └── <local-session-id>/
        ├── metadata.json
        ├── session_state.json
        ├── recording_<timestamp>.m4a
        ├── recording_<timestamp>.json
        ├── transcript.txt
        └── session.json
```

- `metadata.json` remains the minimal existing session marker.
- `session_state.json` is the mutable, authoritative recovery manifest and is always written atomically.
- The recording sidecar remains for Audio Files compatibility and recording-specific metadata.
- `transcript.txt` is written atomically immediately after final Speech output and before an LLM request.
- `session.json` remains the finalized compatibility, export, aggregation, dashboard, and upload artifact.

Before recording, the app should check available device capacity when the platform can provide a practical result. If capacity is clearly insufficient, recording must not start and the interviewer must receive a non-destructive storage warning. This preflight is an additional safeguard, not a substitute for verifying the actual file after Stop.

Required ordering after Stop:

1. Stop and release `AVAudioRecorder`.
2. Verify the `.m4a` exists, is readable, and has a nonzero size.
3. Finalize trajectory data if present.
4. Atomically write `session_state.json` with `audio_status = recorded_locally`.
5. Only then offer or automatically begin transcription/analysis.

If audio verification or draft persistence fails after recording, the app must keep every file that was successfully written, show a local-save error, avoid downstream processing, and keep the current participant/session active for recovery or diagnosis. It must not reset to the next participant until both the readable, nonzero `.m4a` and authoritative manifest can be verified, unless the interviewer explicitly confirms deletion through an existing destructive flow.

## 8. Location design

### 8.1 Typed acquisition result

Location acquisition returns a typed result rather than throwing an opaque error:

- available device GPS;
- permission denied/restricted;
- location services unavailable;
- timeout;
- low accuracy.

Phase 2 uses an initial maximum horizontal-accuracy threshold of 50 meters and a maximum age of 60 seconds. Results at 10 meters or better are classified `high`, results above 10 through 50 meters are `acceptable`, and results above 50 meters are `low`. Low-accuracy coordinates are persisted for the recovery choice but are used as the device-GPS start point only when the interviewer explicitly chooses **Use Low-Accuracy GPS**. The 50-meter value is deliberately visible and testable and should be field-tested before production rollout.

### 8.2 Recording without GPS

- `location_source = none`.
- Latitude, longitude, and accuracy remain null.
- `location_status` records the exact reason.
- `recording_start_trajectory_point` is omitted/null.
- `trajectory_points` may be empty.
- Recording, transcription, analysis, export, and upload remain valid.

### 8.3 Apple place search

- Implement with `MKLocalSearchCompleter`, `MKLocalSearch`, and `MKMapItem`; no third-party dependency is permitted.
- Debounce completion queries by 300 milliseconds. The implemented UIKit search supports address and point-of-interest results, including addresses, landmarks, and buildings.
- A selected MapKit result is a valid interview location even though it is not device GPS.
- Save a selected-place object with display label, formatted postal address, latitude, and longitude in the recoverable draft and finalized `session.json`.
- Set `location_source = place_search` and `location_status = available`.
- Carry the place label, formatted address, coordinates, and source through local export and display them in Dashboard detail and map views wherever a location is applicable.
- Map views must render the selected place as a place marker with place-search labeling, not as a GPS start point or trajectory.
- Do not copy the place coordinate into `recording_start_trajectory_point` or trajectory arrays.
- Do not label the selected place, its coordinates, or its map marker as GPS.
- Server GPS index columns remain null for place-search-only interviews. Add separate nullable place/location-source index fields only if querying them is required.
- MapKit search can fail despite a favorable network hint. Failure returns to the GPS recovery choices without affecting an already saved recording.

### 8.4 Implemented Phase 2 behavior

- The session manifest is created with `location_status = acquiring` before the GPS request begins, and every retry, failure, no-GPS choice, low-accuracy acceptance, and place selection is saved atomically before recording starts.
- The recovery alert offers Try GPS Again, Record Without GPS, Search for an Address or Place, and Cancel Interview. A low-accuracy candidate additionally offers Use Low-Accuracy GPS.
- `session_state.json` schema version 2 includes explicit location quality, horizontal accuracy, a coordinate object whose latitude/longitude encode as null when unavailable, and an optional selected-place snapshot.
- Place-search coordinates populate the resolved location object in `session.json`, local export, Dashboard detail, and the map place marker. They never populate `recording_start_trajectory_point` or `trajectory_points`.
- Trajectory sampling starts only for accepted device GPS. Subsequent location failures are non-blocking and retain already captured points.
- The questionnaire chooser always includes the already loaded bundled questionnaire when the remote/cache list is empty, preserving first-launch offline collection even when the Survey API is configured.

## 9. Transcription and analysis design

### 9.1 Speech policy

- Inspect `supportsOnDeviceRecognition` for the selected recognizer/locale.
- When processing without a usable network hint, attempt Speech only if on-device recognition is supported and set `requiresOnDeviceRecognition = true`.
- When a network hint is available, Speech may use its normal path, but the actual recognition result/error is authoritative.
- Never infer offline capability from `recognizer.isAvailable` alone.
- Unsupported or failed transcription remains retryable; it must not alter or delete the audio.

### 9.2 Transcript durability

1. Set transcription state to `in_progress` atomically.
2. Run Speech against the saved `.m4a`.
3. Write final text atomically to `transcript.txt`.
4. Update the draft to `transcription_status = completed` and record the transcript filename.
5. Only after both writes succeed may the LLM request begin.

### 9.3 Analysis and clarification durability

- LLM failure sets `analysis_status = pending_retry`, stores sanitized error information, and waits for an explicit/manual or later approved scheduled retry.
- Parsed matches are persisted before presenting clarification UI.
- Each clarification update is persisted as it is completed so termination does not restart completed prompts.
- `session.json` is generated only when required clarification has completed or unresolved items have been explicitly preserved according to the current clarification behavior.

### 9.4 Implemented Phase 3 behavior

- `DurableInterviewProcessingCoordinator` is the single stage resolver. It verifies that the original audio is a readable, nonempty playable media file, then resumes from transcription, analysis, clarification, or ready-to-upload state by reading `session_state.json` and the session folder. A legacy header-only/corrupt recording is marked as a terminal audio failure, retained locally, and excluded from automatic Speech retries.
- Apple Speech capability inspection records `supportsOnDeviceRecognition`, normal service availability, and authorization. When the network path hint is unsatisfied, the request sets `requiresOnDeviceRecognition = true` only when the recognizer explicitly supports it. Otherwise transcription remains `pending` with `on_device_speech_unavailable`; the UI does not claim offline Speech is available.
- Successful Speech output is atomically written to `transcript.txt`, reread from disk, and only then supplied to the LLM. Older manifests containing an embedded completed transcript are migrated by atomically creating `transcript.txt` before analysis resumes.
- Speech and LLM failures transition to `pending_retry`, persist a stage-specific error category plus retry count, last error, and attempt time, and present Try Again or Process Later. No failure path displays a saved-success message or automatically deletes audio.
- The coordinator accepts injected Speech, LLM, connectivity, and transcript-store implementations. It suppresses concurrent work for the same local session UUID.
- Parsed matches are saved before clarification. Manually completed clarification items are skipped after restart, while unfinished items resume through the existing provider, prompt, multiple-choice, checked-option, and clarification behavior.
- On launch, the app offers the newest recoverable interview; Session Tools also exposes Resume Saved Interview. Rehydration restores frozen questionnaire/respondent snapshots, the original audio path, checked options, trajectory, and cloud identifiers. Inactivity reset clears only active UI state and leaves this recovery path intact.
- Legacy sidecars created before questionnaire snapshots existed are backfilled with the bundled questionnaire when the interviewer explicitly resumes them. Apple Speech tasks have a bounded 120-second timeout so a recognizer callback that never completes cannot leave recovery running indefinitely.
- After clarification, `session.json` is written atomically and `upload_status` becomes `pending`, which derives to `ready_to_upload`. Phase 3 stopped at that durable boundary; the implemented Phase 4 outbox now consumes it.

## 10. Connectivity and retry design

### 10.1 Connectivity semantics

`NWPathMonitor` is a scheduling hint only. A satisfied path does not prove that Apple Speech, MapKit, an LLM provider, the configured VM, DNS, TLS, authentication, or the Survey API is reachable.

Actual request results always determine state. Timeouts, connection errors, HTTP errors, authentication errors, decoding failures, and malformed payloads enter the same durable failure/retry handling, with permanent configuration errors displayed clearly to the user.

### 10.2 Retry triggers

Retry eligible work:

- at app launch for upload-ready packages;
- when the app enters the foreground for upload-ready packages;
- after `NWPathMonitor` changes to satisfied while the app is active for upload-ready packages;
- when the interviewer taps Try Again;
- when the interviewer opens a recoverable dashboard draft and chooses Resume Processing.

Launch, foreground, and path triggers scan every manifest but do not silently start Apple Speech or LLM work. Incomplete content processing remains an explicit interviewer action through the recovery prompt or **Retry Pending Sessions Now**; finalized package upload may retry automatically.

Foreground retry is the guaranteed behavior. This design does not add `BGTaskScheduler` and does not promise execution while the app is suspended or terminated.

### 10.3 Backoff

- Automatic retries use bounded exponential backoff with jitter.
- The first retry begins around 30 seconds, followed by increasing delays capped at approximately two hours.
- `next_retry_at` prevents repeated foreground/path callbacks from creating a request storm.
- Manual Try Again ignores `next_retry_at` but increments retry metadata and cannot run concurrently with an existing attempt.
- A successful stage clears its retry error and advances to the next incomplete state.

### 10.4 Idempotent cloud-session creation

- New cloud-session creation is deferred until recording has stopped and the original local audio has been verified as a readable, nonzero `.m4a` with an atomically persisted recovery manifest.
- This intentionally replaces the current best-effort `ensureCloudSessionCreated()` request that starts after respondent submission and before recording.
- No cloud-session request may run during interview preparation or recording, even when connectivity appears available.
- Extend the session-create request with an optional local-session idempotency UUID.
- Existing callers that omit it keep current behavior.
- When supplied, the server returns the existing cloud respondent/session mapping for that local UUID or creates it once.
- The app persists returned identifiers before package upload.
- Repeating the request after a lost response must return the same identifiers rather than creating a duplicate respondent/session.
- The server change must be additive and accompanied by an additive migration for the existing database.

### 10.5 Implemented Phase 4 behavior

- `DeferredSessionOutbox` scans `Documents/SurveySessions/*/session_state.json`; session folders, not a global queue file, are the durable source of truth. Legacy folders are conservatively synthesized into a manifest before they enter processing.
- The outbox starts on app launch, observes foreground activation, treats a satisfied `NWPathMonitor` path as a scheduling trigger, runs after a newly finalized package, and exposes **Retry Pending Sessions Now** in Session Tools. Manual retry bypasses `next_retry_at`.
- Automatic launch/foreground/path runs upload finalized packages only. They report incomplete transcription/analysis/clarification as deferred rather than starting Speech or LLM behind the recovery UI. An explicit manual retry invokes `DurableInterviewProcessingCoordinator` at the earliest incomplete stage; upload still requires verified nonempty `session.json` and original `.m4a` files.
- A process-wide run guard plus per-session active IDs prevent duplicate concurrent work. Automatic failures use exponential delays beginning at 30 seconds, capped at two hours, with 20 percent jitter; retry count, attempt time, next retry time, and error text are saved atomically in the session manifest.
- Cloud respondent/session IDs are requested only after local audio and final-package verification and are persisted before upload. `POST /sessions` now accepts optional `local_session_id`; `session_creation_keys` maps it to exactly one respondent/session, protected by a per-key MySQL advisory lock. Existing clients that omit the field retain the prior behavior.
- `POST /sessions/{session_id}/package` remains an upsert by cloud session ID. A repeated upload after a lost response replaces the same package index and derived answers rather than creating a second package. The app validates returned IDs, JSON/audio paths, byte counts, and hashes before setting `upload_status = uploaded`.
- The successful upload marker is written both to the authoritative manifest and to the recording sidecar for compatibility with existing Audio Files and Dashboard behavior. Original local audio is retained.
- `PendingSurveyUploadStore` was removed after repository-wide reference inspection confirmed that no active workflow used it; it only represented the disabled legacy answer-row queue.
- No `BGTaskScheduler` or background `URLSession` mechanism was added. Launch/foreground/reachability/manual processing is reliable while the app is running, but work is not guaranteed while iOS has suspended or terminated the app.
- Automatic outbox callbacks verify `UIApplication.applicationState == .active` before scanning or starting network work. The obsolete background-location declaration and lifecycle-time `CLLocationManager` startup were removed; recording GPS is created only by explicit foreground interview actions.

## 11. Resumable coordinator and UI

Introduce one processing coordinator that loads a draft and advances only the next eligible state. `ViewController` remains the interview UI owner but no longer contains four separate connectivity/GPS pipelines.

### 11.1 After GPS failure

Show:

- Try GPS Again
- Record Without GPS
- Search for an Address or Place
- Cancel Interview

The message must name the cause when known: permission denied, timeout, unavailable services, or low accuracy.

### 11.2 After recording

The local audio/draft save finishes before presenting actions. The review flow offers:

- playback;
- Analyze Answers or Try Again;
- Finish and Process Later;
- confirmed Discard Recording.

Finish and Process Later resets the active UI only after the durable draft is verified. It never deletes the session.

### 11.3 Dashboard recovery

Dashboard discovery must include `session_state.json` drafts even when `session.json` does not yet exist. Each row shows:

- lifecycle/status;
- location source/status;
- last error when present;
- next retry time when scheduled;
- Resume/Try Again action;
- existing share/map/delete actions when applicable.

Finalized legacy packages without a draft continue to load through the current parser.

## 12. Retention and deletion

### 12.1 Automatic cleanup

- Empty metadata-only folders remain eligible for cleanup when they contain no `.m4a` and no `session.json`; a manifest left in `preparing` state without audio is not treated as an interview recording.
- Any session with an `.m4a` that is not durably marked uploaded is retained indefinitely.
- Any draft or finalized package with `upload_status != uploaded` is retained indefinitely.
- Legacy folders with no reliable upload marker are conservatively treated as unuploaded.
- Uploaded sessions may continue using the current newest-50/seven-day policy.
- Inactivity reset clears in-memory/UI ownership only; it never removes recorded files.

### 12.2 Explicit deletion

Existing explicit deletion remains allowed after confirmation:

- current recording discard;
- Audio Files deletion;
- Dashboard local-session deletion.

Warnings must state when the item is unuploaded and that the action deletes the only known copy. Dashboard batch deletion must provide the same protection. Server deletion remains a separate admin action and is not implied by deleting a device copy.

## 13. Backward compatibility and migration

- Keep the existing `session.json` keys, ordering expectations, questionnaire IDs, matched-question structure, export behavior, aggregation behavior, and package endpoint.
- Add new fields in a backward-compatible way; older decoders must continue to ignore them.
- New decoders use `decodeIfPresent` defaults for older drafts/packages.
- Existing session folders are discovered as follows:
  - folder with `session.json`: finalized legacy session; synthesize display state from package and upload sidecar marker;
  - folder with `.m4a` but no package: recoverable legacy draft; synthesize conservative pending states without rewriting until the user resumes or migration is explicitly performed;
  - metadata-only folder: eligible for empty cleanup under current safety checks.
- Preserve all existing UserDefaults keys unless a separately documented migration is introduced.
- Keep `SurveyExports` fallback aggregation and `DashboardCache` behavior.
- Add database columns/tables only through an idempotent migration script. Do not rebuild or destructively replace existing tables.
- Do not change credentials, API keys, bundle identifiers, signing, ATS deployment addresses, or questionnaire IDs.

## 14. Implementation phases

### Phase 1: Durable state and safe retention

- Add versioned draft/state models and an atomic store.
- Add lifecycle derivation and legacy-folder discovery.
- Persist frozen respondent, interviewer, and questionnaire snapshots before recording.
- Protect unuploaded work from retention.
- Add unit tests for decoding, atomic state transitions, lifecycle derivation, migration, and retention eligibility.

### Phase 2: Optional location

- Status: implemented in the location-resolution phase; field/device UI validation remains required.
- Return typed location outcomes and apply an accuracy policy.
- Replace the hard GPS gate with the four recovery choices.
- Support recording with null location.
- Add native MapKit place search with separate place metadata.
- Test denied permission, disabled services, timeout, low accuracy, no GPS, and search failure.

### Phase 3: Durable transcription and analysis

- Status: implemented; physical-device validation of locale-specific on-device Speech assets remains required.
- Verify audio and draft durability on Stop.
- Add `transcript.txt` persistence before LLM invocation.
- Implement explicit on-device Speech handling.
- Persist analysis and clarification progress.
- Add Finish and Process Later.

### Phase 4: Retry and idempotent upload

- Status: implemented; deployment requires the additive `session_creation_keys` migration and physical server integration validation.
- Foreground `NWPathMonitor` scheduling, launch/foreground/manual triggers, persisted backoff, and duplicate suppression are implemented. Automatic triggers upload finalized packages; Speech/LLM resumption requires an explicit recovery/manual action.
- Cloud-session creation uses optional `local_session_id`; package uploads resume from verified local files and only validated responses mark the manifest uploaded.
- Mocked tests cover unreachable APIs despite path hints, offline-to-online recovery, timeouts/backoff/manual override, duplicate suppression, lost creation/upload responses, relaunch scanning, and repeated-upload suppression.

### Phase 5: Dashboard and file-management integration

- Status: implemented; physical-device accessibility/layout validation remains required.
- Dashboard discovery includes manifest-only drafts and derives a single truthful status summary from persisted state. Local save, completed analysis, scheduled retry, and confirmed upload are distinct states.
- Rows/details identify safe local audio, missing/low-accuracy/manual-place location, pending transcription/analysis/clarification/upload, scheduled retry, confirmed upload, and action-required failure.
- Eligible local rows expose a per-session Retry Now action. The location detail preserves null/pending/source fields and exposes a future editing seam without implementing a large editor.
- Local/cached/server rows, aggregation, export, place markers, and device-GPS trajectory maps remain compatible. Place coordinates are never placed into or indexed as device-GPS trajectory data.
- Single and batch deletion warnings identify unuploaded-only-copy risk. Explicit Audio Files deletion updates the manifest so the missing original cannot be retried or shown as safely recorded.

### Phase 6: Server indexing, documentation, and release verification

- Status: implementation and automated local verification complete; deployed GCP and real-device field tests remain.
- Server summaries preserve a searched-place label while indexing GPS columns only for `location.source = device_gps`. Incoming file bodies are staged, flushed, and atomically replaced so interrupted writes do not expose partial package files.
- The only database addition remains the idempotent `session_creation_keys` migration described in Phase 4; no credentials, signing values, questionnaire IDs, or deployment addresses changed.
- README, this specification, and the ignored `AGENTS.md` session log record the integrated behavior and verification boundary.

## 15. Acceptance criteria

### Data safety

- When practical, available device capacity is checked before recording; clearly insufficient capacity blocks recording with a non-destructive warning.
- The implemented preflight uses 100 MB as the conservative initial threshold when iOS reports capacity; an unavailable capacity reading does not itself block field collection.
- A nonempty `.m4a` exists before any Speech, LLM, cloud-session, or upload request.
- After Stop, the app verifies that the `.m4a` is readable and nonzero and that the authoritative manifest was atomically persisted.
- The app never resets to the next participant when audio verification or manifest persistence cannot be confirmed; it keeps the current session recoverable until the save succeeds or the interviewer explicitly confirms deletion.
- New cloud-session creation does not begin until the verified local-audio and manifest guarantees above are satisfied.
- GPS, Speech, LLM, network, server, and app-restart failures never automatically delete that audio.
- A completed transcript exists on disk before the first LLM request.
- Unuploaded work survives retention, inactivity reset, app restart, and repeated failures.

### Four operating cases

- Internet/GPS available completes the normal flow and uploads.
- Internet unavailable/GPS available records and safely defers unsupported network work.
- Internet available/GPS unavailable supports retry, no-GPS recording, and MapKit place search.
- Internet/GPS unavailable records a complete recoverable local draft and resumes later.

### Recovery and retry

- Termination after recording, transcription, analysis, clarification, cloud-session creation, or during upload resumes at the next incomplete state.
- Retry does not duplicate cloud sessions or concurrent requests.
- `NWPathMonitor` never marks a request successful; only the real service response can do so.

### Compatibility

- First offline launch uses bundled `questionnaire.json` with stable IDs.
- Existing `session.json` packages remain readable, shareable, aggregatable, cacheable, and uploadable.
- Missing/device/place location is represented accurately; a MapKit place is preserved in the draft, final package, export, Dashboard, and map views without entering or being labeled as device-GPS trajectory data.
- Explicit deletion always requires confirmation and clearly identifies the risk to unuploaded data.

### Status truthfulness

- A locally safe recording is labeled as saved locally even when later work is pending.
- **Uploaded** appears only after a validated server response has atomically updated the manifest to `upload_status = uploaded`.
- **Analysis complete** is never inferred merely from the existence of audio or a local draft.
- Retrying or failing a network stage cannot erase a previously persisted transcript, package, or original recording.

## 16. Test plan

### Unit tests

- Round-trip every draft state and decode missing/unknown fields.
- Validate lifecycle derivation for all state combinations.
- Test retry backoff, jitter bounds, manual override, and concurrent-attempt exclusion.
- Test location outcome mapping and low-accuracy classification.
- Test retention eligibility for empty, legacy, pending, failed, ready, and uploaded sessions.
- Test migration/discovery of `.m4a`-only and `session.json`-only folders.
- Test that LLM coordination refuses to run without a durable transcript.

### UI/integration tests

- Exercise all GPS recovery actions.
- Verify no-GPS and place-search recording screens and saved labels.
- Verify Try Again and Finish and Process Later after Speech/LLM/network failures.
- Relaunch at each processing boundary and resume from Dashboard.
- Verify unuploaded single and batch deletion warnings.
- Verify legacy Dashboard, Audio Files, map, export, and aggregation flows.

### Network/server tests

- Test offline path hints, misleading satisfied hints, DNS failure, timeout, TLS/connection failure, 401, 404, 429, 500, and invalid JSON.
- Drop the cloud-session response after server creation and confirm retry returns the original identifiers.
- Repeat package uploads and confirm idempotent index replacement without duplicate derived answers.
- Upload packages with device GPS, place-search-only location, and no location.

### Device verification

- Test a device/locale with on-device Speech support and one without support.
- Confirm `requiresOnDeviceRecognition` prevents network fallback when explicitly selected.
- Test airplane mode, denied Location permission, disabled Location Services, indoor low accuracy, and restored connectivity.
- Inspect the Files-visible session folder after every forced failure.
- Create more than 50 unuploaded sessions and confirm all remain protected while uploaded sessions alone remain eligible for the configured age/count cleanup.
- Force insufficient-capacity and zero-byte/unreadable-audio outcomes and confirm the UI blocks reset until the user explicitly discards.

### Final integration verification boundary

Automated tests cover manifest encoding/defaults, lifecycle/status truthfulness, all four GPS/network state combinations as persisted-state matrices, location classification, retention protection beyond 50 sessions, retry/backoff/manual override, network/server failure despite path hints, duplicate suppression, response-loss idempotency, relaunch scanning, and place-versus-GPS server indexing. Simulator unit tests and a generic simulator build verify compilation and non-UI state behavior. The GPS/Speech permission sheets, device storage reporting, actual radio loss, process termination timing, accessibility/layout, and a live GCP/MySQL upload must still be exercised manually on a signed physical iPhone or iPad.

## 17. Risks and open questions

- On-device Speech support depends on device, locale, OS, and installed assets. Pending transcription is the required fallback.
- `MKLocalSearch` uses Apple APIs but commonly requires Apple Maps network service. Search failure must remain non-destructive.
- iOS does not guarantee arbitrary background execution. This version guarantees foreground resumption only.
- Audio can consume significant device storage when unuploaded sessions are retained indefinitely. A future storage-management UI may warn about space but must never silently delete unuploaded work.
- Phase 2 selected an initial visible 50-meter acceptable GPS threshold (10 meters or better is high quality); it remains subject to field testing and must not become a silent rejection policy.
- The existing live database contains core tables not fully defined in `server/schema.sql`. The idempotency migration must inspect the deployed schema before rollout and remain additive.
- Error messages persisted in drafts must be sanitized so credentials, authorization headers, and sensitive response bodies are never stored.

These risks do not change the core invariant: loss of optional services must result in a recoverable local interview, not loss of the recording.
