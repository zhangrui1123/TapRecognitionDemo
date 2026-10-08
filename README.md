# TapRecognition HarmonyOS Deployment

This is a HarmonyOS phone demo for an IMU double-tap classifier. The UI is intentionally secondary. This document records the model deployment contract needed to safely move a trained TapRecognition PyTorch checkpoint to HarmonyOS.

The model is stateful. Replacing only the `.ms` file is not sufficient unless its tensor contract, preprocessing, and alarm policy all still match the app.

## Current Artifact

| Item | Current value |
| --- | --- |
| Source checkpoint | `TapRecognition/testing_checkpoints/lstm64_features/d8(102)/best.pt` |
| Checkpoint epoch / seed | 21 / 102 |
| Checkpoint SHA-256 | `6a0d69c81717280af300b444dbcdeb5d18beddd7cdad60b80c626a0b5393aeb6` |
| Default bundled model | `entry/src/main/resources/rawfile/tap_feature_step.ms` |
| Bundled model size | 198,120 bytes |
| Bundled model SHA-256 | `75711d93d90a1bdbcd7f7a645eb5df8b48f924eb217f65ae5e140e6beef61ff9` |
| Export format | ONNX opset 14, one causal frame per invocation |
| Converter/runtime used | MindSpore Lite 2.9.0 CPU runtime |
| Runtime context | CPU, one thread, `enforce_fp32` |
| Model architecture | 20 causal features with frozen normalization, causal CNN, one 64-unit LSTM layer, three output classes |
| Class order | `0 = none`, `1 = left`, `2 = right` |

The checkpoint model configuration is:

```text
input_dim=6, num_classes=3, cnn_channels=32,
lstm_hidden=64, lstm_layers=1,
kernel_size=5, dilations=(1, 2, 4), dropout=0.1,
feature_config: version=1, magnitudes=True, differences=True,
difference_magnitudes=True, rms_windows=(5, 15)
```

The converted artifact passed full-sequence PyTorch, streaming PyTorch, ONNX Runtime, and MindSpore Lite checks on 1,800-frame left, right, and negative recordings, plus a 600-frame test resetting the model every 67 frames. The installed file passed a further 360-frame right recording. Maximum observed MindSpore probability difference was `1.53e-5`, hidden-state difference `1.16e-4`, and cell-state difference `6.39e-4`. Feature history and its ready flag matched exactly. See [verification record](docs/feature_model_verification.json).

The verifier requires ONNX/PyTorch differences below `1e-4` and MindSpore differences below `2e-3` for probabilities and every carried state tensor.

This is an offline runtime-equivalence check, not a substitute for installation and physical-device testing.

## Select the Model or Roll Back

Both model files are bundled in the same HAP. The previous raw-IMU file is preserved byte-for-byte:

| Profile | File | Checkpoint | SHA-256 of `.ms` |
| --- | --- | --- | --- |
| Features (default) | `tap_feature_step.ms` | `lstm64_features/d8(102)/best.pt`, epoch 21 | `75711d93d90a1bdbcd7f7a645eb5df8b48f924eb217f65ae5e140e6beef61ff9` |
| Raw baseline | `tap_step.ms` | `lstm64d8/best.pt`, epoch 36 | `d5268f075f7e8be744abb04c93eabb8548cbd2cff0d34d94949dc73227c6657f` |

Baseline checkpoint SHA-256: `7e278b3aeca5f2667079171546ebe3272bcfa9d01301b66f3a3c92191dc1efe2`.

The preserved baseline was reverified against its PyTorch checkpoint on a 600-frame right recording during this deployment (`ms_prob` maximum absolute error `8.89e-6`).

**On the phone:** open the demo, tap the post's follow button to show **识别调试** (recognition debug), and press **切回原始 IMU 模型** to switch to the baseline. Press **切换特征 IMU 模型** to return to the feature model. The debug panel displays the selected profile. Detection counters restart when switching. The selection lasts for this page instance; reopening the page uses the build default.

**For a baseline-default build:** change this one line in `entry/src/main/ets/model/TapModelProfiles.ets`, then rebuild:

```typescript
export const DEFAULT_TAP_MODEL: TapModelVariant = TapModelVariant.Raw;
```

Switching stops the IMU collector, discards queued samples and in-flight inference results, waits for the current prediction, loads and validates the selected tensor contract, and resets all state before restarting. A load failure is shown in the debug panel; the app does not silently substitute another model. The other profile can still be selected for recovery.

Do not replace `tap_step.ms` with the feature artifact: the baseline has four inputs/outputs, while the feature model has six. `TapModelProfiles.ets` is the source of model filenames, feature-history sizes, and per-profile thresholds.

## Engineered Features and Frozen Normalization

As in `main_notebooks/training_feature_lstm.ipynb`, feature computation happens **inside the model graph after the phone's high-pass filter**. ArkTS sends the same six axes for both profiles. It must not precompute or normalize the 20 features again.

The ordered feature vector is:

```text
0..5:   acc_x, acc_y, acc_z, gyro_x, gyro_y, gyro_z
6..7:   acceleration vector magnitude, gyro vector magnitude
8..13:  per-sample signed differences of the six axes (not divided by dt)
14..15: acceleration/gyro difference-vector magnitudes
16..17: acceleration/gyro trailing RMS, 5 samples
18..19: acceleration/gyro trailing RMS, 15 samples
```

RMS is `sqrt(mean(vector_energy) + 1e-8) - 1e-4`. The divisor is always the full window length, with zero prehistory at startup. The first frame's differences are zero, even if that first IMU observation is nonzero. A separate `feature_ready` tensor distinguishes startup from a real previous observation of zero.

Per-feature `(value - mean) / scale` uses checkpoint buffers fitted once on unaugmented **training windows only** (675,600 frames). These constants and the learned projection are embedded in ONNX and `.ms`; no live-session fitting, EMA, external normalization file, or validation refit is involved.

The checkpoint used an eight-frame positive-label delay. This is a training target shift, not an instruction to shift incoming samples or add a second delay in preprocessing. Keep it in mind when evaluating end-to-end alarm latency.

## Why This Deployment Is Special

The training model runs on a full IMU sequence. A phone receives one sample at a time. To produce the same causal result, the phone must preserve all model history between calls:

1. The causal CNN history buffer.
2. The LSTM hidden state.
3. The LSTM cell state.
4. The filter state used by preprocessing.
5. For the feature profile, the 14-frame high-passed axis history and startup flag.

The old `tap_recognition.ms` batch model used a sliding window and did not preserve recurrent state. It is obsolete for this use case.

Do not use an ONNX `LSTM` or `GRU` operator for this model. MindSpore Lite conversion can succeed while recurrent outputs diverge from PyTorch. `tap_recognition/model_lstm.py` implements the trained LSTM gates explicitly using PyTorch's input, forget, candidate, output gate order. The exported ONNX graph therefore contains primitive operations rather than a recurrent ONNX operator.

## End-to-End Runtime Pipeline

```text
Accelerometer + gyroscope callbacks
    -> timestamp alignment and linear interpolation onto a 100 Hz grid
    -> 6-channel 100 Hz Butterworth high-pass filter
    -> selected .ms one-frame inference (features/normalization inside feature graph)
    -> left/right alarm policy
    -> demo UI and haptic response
```

Relevant implementation files:

| File | Responsibility |
| --- | --- |
| `entry/src/main/ets/model/ImuStreamCollector.ets` | Collects accelerometer and gyroscope values, aligns timestamps, and emits ordered 100 Hz six-channel samples. |
| `entry/src/main/ets/model/TapPreprocessor.ets` | Training-equivalent high-pass filter and filter reset. |
| `entry/src/main/ets/model/TapDetector.ets` | Stateful MindSpore Lite inference, state feedback, input queue, and alarm policy. |
| `entry/src/main/ets/model/TapModelProfiles.ets` | Model filenames, feature-history contract, per-profile thresholds, and build default. |
| `entry/src/main/ets/pages/DemoPage.ets` | Loads the selected model, connects the IMU stream, and provides the debug rollback switch. |
| `TapRecognition/tools/export_step_for_harmony.py` | Exports a trained checkpoint as a single-frame streaming ONNX graph. |
| `TapRecognition/tools/verify_harmony_lstm_step.py` | Checks full PyTorch, streaming PyTorch, ONNX Runtime, and MindSpore Lite outputs. |

## Model Tensor Contract

All current tensors are contiguous `float32`. MindSpore input and output ordering is positional in `TapDetector.ets`; preserve this order exactly.

| Position | Tensor | Shape | Meaning |
| --- | --- | --- | --- |
| Input 0 | `imu` | `[1, 1, 6]` | One high-passed accelerometer/gyroscope sample, not 20 features. |
| Input 1 | `cnn_buffer` | `[1, 32, 29]` | Packed causal CNN input history. |
| Input 2 | `h_in` | `[1, 1, 64]` | LSTM hidden state for all layers. |
| Input 3 | `c_in` | `[1, 1, 64]` | LSTM cell state for all layers. |
| Output 0 | `prob` | `[1, 1, 3]` | Softmax probabilities in `(none, left, right)` order. |
| Output 1 | `h_out` | `[1, 1, 64]` | Updated hidden state. |
| Output 2 | `c_out` | `[1, 1, 64]` | Updated cell state. |
| Output 3 | `cnn_buffer_out` | `[1, 32, 29]` | Updated causal CNN history. |

Feature profile only (after the four common tensors above):

| Position | Tensor | Shape | Meaning |
| --- | --- | --- | --- |
| Input 4 | `feature_history` | `[1, 14, 6]` | Prior high-passed IMU axes, zero-padded at startup. |
| Input 5 | `feature_ready` | `[1]` | Zero at reset; one after the first observation. |
| Output 4 | `feature_history_out` | `[1, 14, 6]` | Updated feature history, fed back unchanged. |
| Output 5 | `feature_ready_out` | `[1]` | Updated startup flag, fed back unchanged. |

The feature model's total finite-history receptive field is 43 frames: 29 CNN frames plus 14 feature-history frames. **The CNN buffer remains `[1,32,29]`, not `[1,32,43]`.** Reset both histories and the startup flag together. The graph uses explicit primitive LSTM gates for this profile too.

For an LSTM with `L` layers and hidden width `H`, hidden and cell shapes are `[L, 1, H]`. The app stores these shapes as flat `Float32Array`s. The current one-layer 64-unit model therefore uses 64 values each for `hState` and `cState`.

The CNN buffer is not an arbitrary rolling window. It holds the input history needed by the three causal convolution blocks: 4, 8, and 16 prior samples, plus the reserved final slot. Its total receptive field is 29 frames. Always feed back `cnn_buffer_out`; do not attempt to recreate this packed layout in ArkTS.

`forward()` returns logits during normal PyTorch training evaluation. `step()` returns softmax probabilities. The verifier compares `softmax(forward())` with every one-frame `step()` output.

## Preprocessing and Sample Ordering

The model expects six values in this exact order:

```text
accX, accY, accZ, gyroX, gyroY, gyroZ
```

`ImuStreamCollector` interpolates the two sensor streams onto a 10 ms grid. `TapPreprocessor` then applies a per-channel second-order Butterworth high-pass filter with a 0.5 Hz cutoff at 100 Hz. Its coefficients match `scipy.signal.butter(2, 0.5 / 50, 'high')` used for training.

Important compatibility rules:

- Do not add EMA normalization. The current model was trained without it.
- Do not change the sensor axes, units, channel order, sample rate, or interpolation behavior without retraining or revalidating the model.
- Reset the high-pass filter, CNN buffer, recurrent states, feature history, startup flag, and alarm state together at a real stream boundary by calling `TapDetector.reset()`.
- Every emitted frame must be processed in order. If frames are skipped, the filter, CNN, and LSTM histories no longer describe the same sequence.

`TapDetector.processSample()` uses a FIFO queue because `model.predict()` is asynchronous. Replacing the queue with a single "latest pending sample" slot would drop intermediate frames and corrupt state continuity under load. If the queue reaches 100 samples (one second), the detector resets the stream and drops the stale backlog rather than reporting old sensor data indefinitely.

`pause()` invalidates in-flight results and waits for the drain to finish before a model change. Prediction errors reset the whole stream state instead of continuing with an advanced filter and stale recurrent state. Input names/shapes and output names/lengths/finiteness are checked before activation and on returned predictions.

## Alarm Policy

The model returns per-frame class probabilities. It does not emit an alarm itself. `TapDetector.ets` applies the product policy:

| Setting | Current value |
| --- | --- |
| Left threshold | `0.65` |
| Right threshold | `0.51` |
| Alarm emission | Immediate on a threshold crossing |
| Refractory period | 50 frames, or 0.5 seconds |
| Refractory scope | Shared between left and right alarms |

On a threshold crossing, the detector emits in that same frame. If both sides are eligible, it selects the higher probability; ties resolve to left. The shared refractory period begins immediately after emission.

Both profiles use the user-selected demo thresholds: left `0.65`, right `0.51`. The saved raw baseline's historical max-F1 threshold was `0.55/0.55`. Edit per-profile thresholds in `TapModelProfiles.ets` and evaluate recall/false alarms independently of conversion equivalence.

## Export a New LSTM Checkpoint

Run these commands from the `TapRecognition` training repository, not from this HarmonyOS project. A compatible checkpoint must contain `model_type`, `model_config`, and `model_state` and must have a correct causal `step()` implementation.

Set paths for the candidate checkpoint and temporary artifacts:

```bash
export CHECKPOINT='testing_checkpoints/lstm64_features/d8(102)/best.pt'
export DEMO_MODEL_FILE=tap_feature_step.ms
export OUT_DIR=/tmp/tap_export
mkdir -p "$OUT_DIR"
```

Inspect the checkpoint configuration before changing the demo contract:

```bash
./.venv/bin/python -c "import torch; c=torch.load('$CHECKPOINT', map_location='cpu', weights_only=True); print(c['model_type']); print(c['model_config'])"
```

Export a single-frame ONNX graph. The exporter calls `model.eval()`, disables dropout, builds the zero states required by the checkpoint, and exports the correct input/output names for GRU, raw LSTM, or feature LSTM models.

```bash
./.venv/bin/python tools/export_step_for_harmony.py \
  --checkpoint "$CHECKPOINT" \
  --output "$OUT_DIR/tap_step.onnx"
```

For an LSTM, inspect the resulting graph before conversion. It must not contain an ONNX `LSTM` or `GRU` node. `tools/verify_harmony_lstm_step.py` asserts this automatically; do not skip the verifier merely because conversion succeeds.

## Convert ONNX to MindSpore Lite

Use the same converter/runtime major version intended for the device. The current artifact was produced with MindSpore Lite 2.9.0. Set `MS_LITE_DIR` to an extracted Linux package containing both the converter and runtime libraries.

```bash
export MS_LITE_DIR=/path/to/mindspore-lite-2.9.0-linux-x64
export LD_LIBRARY_PATH="$MS_LITE_DIR/tools/converter/lib:$MS_LITE_DIR/runtime/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export CONVERTER="$MS_LITE_DIR/tools/converter/converter/converter_lite"

"$CONVERTER" \
  --fmk=ONNX \
  --modelFile="$OUT_DIR/tap_step.onnx" \
  --outputFile="$OUT_DIR/tap_step" \
  --inputShape='imu:1,1,6;cnn_buffer:1,32,29;h_in:1,1,64;c_in:1,1,64;feature_history:1,14,6;feature_ready:1'
```

The output is `$OUT_DIR/tap_step.ms`. Converter success only means the file was produced. It does not prove that recurrent state or probabilities match PyTorch.

For a raw LSTM checkpoint, omit `feature_history` and `feature_ready` from `--inputShape` and set `DEMO_MODEL_FILE=tap_step.ms`. The feature exporter rejects unfitted normalization statistics and currently requires at least one feature-history sample.

For a model with a different number of LSTM layers or hidden width, update the `h_in` and `c_in` dimensions in this command. For any other architecture change, derive all shapes from the exported ONNX graph and update the verifier and app together.

## Verify Numerical Equivalence

Use a left-tap recording, a right-tap recording, and a negative recording. Verify enough frames to exceed the full receptive field and preferably at least one long recording. The LSTM verifier supports the project's six-axis, 3-class, 32-CNN-channel, 64-hidden raw/feature LSTM models with one or two layers.

```bash
./.venv/bin/python tools/verify_harmony_lstm_step.py \
  --checkpoint "$CHECKPOINT" \
  --onnx "$OUT_DIR/tap_step.onnx" \
  --ms "$OUT_DIR/tap_step.ms" \
  --runtime-lib "$MS_LITE_DIR/runtime/lib/libmindspore-lite.so" \
  --recording data_06_10_26/valid_data/imu_Miguel_knock_twice_left_20260921_175305.csv \
  --frames 1800 \
  --report "$OUT_DIR/verification_left.json"
```

Repeat with a right recording and a negative recording. For a longer-state check, the current artifact was also tested with:

```bash
./.venv/bin/python tools/verify_harmony_lstm_step.py \
  --checkpoint "$CHECKPOINT" \
  --onnx "$OUT_DIR/tap_step.onnx" \
  --ms "$OUT_DIR/tap_step.ms" \
  --runtime-lib "$MS_LITE_DIR/runtime/lib/libmindspore-lite.so" \
  --recording data_06_10_26/valid_data/imu_Miguel_shake_phone_20260921_172915.csv \
  --frames 1800
```

The verifier independently maintains PyTorch, ONNX Runtime, and MindSpore Lite CNN/LSTM/feature states. It checks tensor names, order, sizes, finite values, absence of native recurrent ONNX operators, full-sequence PyTorch outputs, one-step PyTorch outputs, and every returned state. A passing result ends with `PASS`. Add `--reset-every 67 --frames 600` for repeated cold starts (model states reset; recording preprocessing remains continuous), and `--report PATH` to save provenance and numerical errors.

After copying the file into the demo, run the verifier once more against the bundled path. This catches a wrong copy or stale build artifact.

```bash
export DEMO_DIR=/path/to/TapRecognitionDemo
cp "$OUT_DIR/tap_step.ms" "$DEMO_DIR/entry/src/main/resources/rawfile/$DEMO_MODEL_FILE"

./.venv/bin/python tools/verify_harmony_lstm_step.py \
  --checkpoint "$CHECKPOINT" \
  --onnx "$OUT_DIR/tap_step.onnx" \
  --ms "$DEMO_DIR/entry/src/main/resources/rawfile/$DEMO_MODEL_FILE" \
  --runtime-lib "$MS_LITE_DIR/runtime/lib/libmindspore-lite.so" \
  --recording data_06_10_26/valid_data/imu_Miguel_knock_twice_right_20260923_113004.csv \
  --frames 360
```

## Install a Verified Model

Copy only a verified `.ms` file, then record its checksum in the Current Artifact table.

```bash
cp "$OUT_DIR/tap_step.ms" \
  "$DEMO_DIR/entry/src/main/resources/rawfile/$DEMO_MODEL_FILE"
sha256sum "$DEMO_DIR/entry/src/main/resources/rawfile/$DEMO_MODEL_FILE"
```

Update `entry/src/main/ets/model/TapDetector.ets` in the same change when the checkpoint contract differs:

| Checkpoint change | Required app update |
| --- | --- |
| LSTM layer count | Set `LSTM_LAYERS`; the hidden and cell arrays become `layers * hidden` floats. |
| LSTM hidden size | Set `LSTM_HIDDEN`; update converter input shapes and all state shape checks. |
| CNN channel count or receptive field | Set `CNN_CHANNELS` and `RECEPTIVE_FIELD`; revalidate the packed CNN buffer. |
| GRU instead of LSTM | Use the three-tensor GRU contract and `tools/verify_harmony_step.py`; do not leave LSTM cell-state code in place. |
| Input channels, class count, or class order | Update preprocessing, tensor checks, UI label mapping, thresholds, and verifier before installation. |
| Different preprocessing or sample rate | Update the phone pipeline to match training exactly, then rerun numerical and physical validation. |
| Feature groups, RMS windows, or normalization statistics | Re-export from the checkpoint; update profile history size and input shapes if needed. Do not refit normalization on phone data. |

Never update a model architecture by changing only `tap_step.ms`. The app intentionally checks the number of inputs, number of outputs, and returned tensor lengths to fail early on a mismatched artifact.

## Build and Device Validation

Open this project in DevEco Studio and install it on a phone after model verification. The entry module targets phones and declares accelerometer, gyroscope, vibration, and gesture-detection permissions. Gesture detection is used by the demo UI; the IMU classifier itself relies on accelerometer and gyroscope samples.

Perform physical testing after every model or preprocessing migration:

1. Confirm the model loads and the IMU stream starts.
2. Test left and right double taps in the intended device orientation and grip.
3. Test representative negative motion such as walking, shaking, handling, and screen interaction.
4. Check that immediate alarms and the 0.5 second shared refractory behavior are acceptable.
5. Capture and label new device recordings if the sensor axes, units, rate, or hardware differ from the training data.

The Linux C-runtime verifier validates the model file, but it does not validate HarmonyOS packaging, sensor calibration, permission behavior, or the device's real-time performance.

The feature deployment compiled and produced a signed HAP using the installed Windows DevEco toolchain. The distributable package is `entry/build/default/outputs/default/entry-default-signed.hap`. Both `.ms` assets are included. Deterministic on-device replay reproduced the delayed feature-profile `none` saturation and isolated a native model-buffer lifetime defect; `TapDetector` now retains the serialized model buffer for the lifetime of the model. See [replay investigation](docs/idle_replay_investigation.md).

The **识别调试** panel shows the selected model, model/collection status, detection count, and the highest tap confidence seen in the previous 150 ms. The voice-bar confidence uses the same rolling peak. This affects display only; per-frame alarm thresholds and timing remain unchanged.

Temporary replay pages, recovery buttons, and deep sensor/runtime diagnostics were removed after the buffer-lifetime fix was verified. The before/after phone reports and investigation remain in `docs/`.

Host lifecycle tests run the actual `TapDetector.ets` through TypeScript transpilation with a mock MindSpore API:

```bash
node --test tests/tap_detector.test.cjs
```

They check FIFO state feedback, feature-to-baseline-to-feature rollback, stale-result cancellation, contract mismatch rejection, and full-state reset after inference failure. They use DevEco's bundled TypeScript by default; set `TAP_TYPESCRIPT_MODULE` to another compatible TypeScript module path if installed elsewhere. They complement the native numerical verifier, rather than replacing it.

## Troubleshooting

| Symptom | Likely cause | Required action |
| --- | --- | --- |
| Model input count differs from the selected profile | Wrong `.ms` file, GRU/LSTM mismatch, or feature/raw mismatch | Raw LSTM expects four tensors; feature LSTM expects six. Inspect the profile and checkpoint `model_type`. |
| Converter succeeds but verifier diverges | Native recurrent ONNX operator, incorrect `step()`, wrong state feedback, or converter/runtime incompatibility | Inspect the graph, retain explicit gates, and compare all state outputs before installing. |
| Phone recall is worse than offline results | Preprocessing, sensor units/axes, resampling, or thresholds differ from training | Restore the exact 100 Hz Butterworth pipeline and re-evaluate thresholds on device data. |
| Detection becomes intermittent under load | Frames are being discarded or reordered | Preserve the FIFO behavior; reset state only at a real discontinuity. |
| Immediate inference shape error | `TapDetector` constants do not match the new model | Update dimensions, output count, and state sizes atomically with the artifact. |
| Wrong side is reported | Class order changed or output tensor order changed | Verify `(none, left, right)` and the ONNX/MindSpore tensor names and positions. |

## Changes from the Original Demo

The deployment-relevant changes made to this demo are:

- Replaced the original GRU state contract with LSTM hidden and cell state feedback.
- Replaced the old batch/window artifact with `tap_step.ms`, a one-frame causal streaming model.
- Changed the filter from an approximate first-order RC plus EMA path to the training-equivalent second-order Butterworth high-pass with no EMA normalization.
- Changed asynchronous inference handling from retaining only a latest pending sample to a FIFO queue so recurrent state cannot skip frames.
- Replaced generic single-score hysteresis with side-specific left/right thresholds, 12-frame peak selection, and one shared 50-frame refractory period.
- Added tensor-count and tensor-length checks so a stale or incompatible model fails rather than silently producing incorrect state updates.
- Added a graph-embedded feature/normalization path, explicit feature-history state, a baseline-preserving model selector, and cancellation-safe reset/rollback.

Keep this README's Current Artifact table and migration commands current whenever the model changes. The checksum, checkpoint configuration, converter version, numerical-verification result, preprocessing, and alarm policy are all part of one deployable model version.
