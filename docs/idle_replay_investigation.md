# Delayed feature-model suppression: deterministic replay

This is a historical investigation record. Temporary on-phone replay code,
fixtures, and diagnostic controls were removed after verification; the
production buffer-retention fix and the before/after evidence remain.

## Reproducer

On 2026-10-06, HDC replay on the connected HarmonyOS phone reproduced the
reported failure without live sensors or physical taps. The test uses the
actual `TapDetector` and its float32-history Butterworth filter, and feeds
recorded raw input at wall-clock 100 Hz.

The fixture contains 600 frames from
`imu_Miguel_knock_twice_right_20260923_113004.csv`, with right events at frames
149 and 513. The alarm thresholds are unchanged at 0.49/0.49. Thirty seconds
of stationary input is enough to reproduce suppression in the original app.

| Feature-model stage before fix | Event 1 peak | Event 2 peak | Alarms | Input-history echo error |
| --- | ---: | ---: | ---: | ---: |
| Fresh | 0.841062 | 0.907215 | 2 | 0 |
| After 30s constant idle | 0.005687 | 0.001636 | 0 | 0.649081 |
| Full state/filter reset | 0.009694 | 0.000063 | 0 | 0.775900 |
| Same-profile reload | 0.841062 | 0.907215 | 2 | 0 |

The returned `feature_history` must contain the current filtered input in
its newest row, independent of the learned classifier or LSTM hidden state.
Its mismatch proves the fault extends beyond learned suppression. The
60-second recorded-quiet case also produced history corruption and 43
inference errors. The raw profile remained responsive in both idle cases.

Full original-device evidence: [replay_phone_before_fix.json](replay_phone_before_fix.json).

## Lifetime fix

The buffer passed to `mindSporeLite.loadModelFromBuffer` used to have no
long-lived ArkTS owner after model activation. `TapDetector` now keeps that
buffer in `modelBacking` for as long as the native model instance is active,
including across `reset()` and `pause()`. Activation replaces the model and
its backing storage together, after outstanding predictions finish.

This single retention change restored the exact input-history echo and
normal tap scores in the on-device replay. No graph, checkpoint, filter,
normalization, thresholds, or recurrent-reset rules were changed for this fix.

| Feature-model stage with backing retained | Event 1 peak | Event 2 peak | Alarms | Input-history echo error |
| --- | ---: | ---: | ---: | ---: |
| Fresh | 0.841062 | 0.907215 | 2 | 0 |
| After 30s constant idle | 0.842936 | 0.907222 | 2 | 0 |
| After 60s recorded quiet | 0.842262 | 0.907222 | 2 | 0 |

Reset and reload again produce the same fresh probabilities. This A/B test
isolates serialized-buffer ownership as the effective fix on this device;
the precise native allocation/finalizer behavior has not been inspected.

The completed post-fix phone run passed all 14 feature/raw stages, each with
600 predictions, two alarms, zero inference errors, and zero feature-input
echo error. Full evidence: [replay_phone_after_fix.json](replay_phone_after_fix.json).

## LSTM-context hypothesis

An LSTM can learn to retain quiet-context information in hidden/cell state
and use it to suppress later tap scores. This is inference-time context,
not online weight training. It is a valid hypothesis to test.

However, in this model all recurrent state, CNN history, feature history,
and the startup flag are explicit input/output tensors. Learned context
should disappear when they are zeroed. It also cannot change a direct
input-history copy operation. The failed history echo, reset/reload
difference, and buffer-retention A/B identify a deployment lifetime defect
for the reproduced failure rather than that learned behavior.

Host replays on PyTorch, ONNX Runtime, and Linux MindSpore Lite tested both
left and right clips with 25, 60, and 180 seconds of constant and recorded
quiet. All feature tests retained 2/2 event peaks above threshold; reset
and reload were exactly equivalent within each runtime. Feature right
peaks stayed approximately 0.842/0.907; left peaks approximately 0.928/0.922.

The phone replay bypasses resampling and physical sensor variations, so it
specifically establishes the runtime defect and recovery for identical
inputs. It does not measure general live-device tap recall.
