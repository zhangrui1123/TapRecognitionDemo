# TapRecognition HarmonyOS Deployment

This is a HarmonyOS phone demo for an IMU double-tap classifier. The UI is intentionally secondary. This document records the model deployment contract needed to safely move a trained TapRecognition PyTorch checkpoint to HarmonyOS.

The model is stateful. Replacing only the `.ms` file is not sufficient unless its tensor contract, preprocessing, and alarm policy all still match the app.

## Current Artifact

| Item | Current value |
| --- | --- |
| Source checkpoint | `TapRecognition/testing_checkpoints/lstm64d8/best.pt` |
| Checkpoint epoch | 36 |
| Checkpoint SHA-256 | `7e278b3aeca5f2667079171546ebe3272bcfa9d01301b66f3a3c92191dc1efe2` |
| Bundled model | `entry/src/main/resources/rawfile/tap_step.ms` |
| Bundled model size | 188,984 bytes |
| Bundled model SHA-256 | `d5268f075f7e8be744abb04c93eabb8548cbd2cff0d34d94949dc73227c6657f` |
| Export format | ONNX opset 14, one causal frame per invocation |
| Converter/runtime used | MindSpore Lite 2.9.0 CPU runtime |
| Runtime context | CPU, one thread, `enforce_fp32` |
| Model architecture | Causal CNN, one 64-unit LSTM layer, three output classes |
| Class order | `0 = none`, `1 = left`, `2 = right` |

The checkpoint model configuration is:

```text
input_dim=6, num_classes=3, cnn_channels=32,
lstm_hidden=64, lstm_layers=1,
kernel_size=5, dilations=(1, 2, 4), dropout=0.1
```

The converted artifact was checked against PyTorch, ONNX Runtime, and the MindSpore Lite C runtime. It passed 600-frame left, right, and negative recordings, plus an 1,800-frame negative recording. The verifier requires ONNX/PyTorch differences below `1e-4` and MindSpore differences below `2e-3` for probabilities and every carried state tensor.

This is an offline runtime-equivalence check, not a substitute for installation and physical-device testing.

## Why This Deployment Is Special

The training model runs on a full IMU sequence. A phone receives one sample at a time. To produce the same causal result, the phone must preserve all model history between calls:

1. The causal CNN history buffer.
2. The LSTM hidden state.
3. The LSTM cell state.
4. The filter state used by preprocessing.

The old `tap_recognition.ms` batch model used a sliding window and did not preserve recurrent state. It is obsolete for this use case.

Do not use an ONNX `LSTM` or `GRU` operator for this model. MindSpore Lite conversion can succeed while recurrent outputs diverge from PyTorch. `tap_recognition/model_lstm.py` implements the trained LSTM gates explicitly using PyTorch's input, forget, candidate, output gate order. The exported ONNX graph therefore contains primitive operations rather than a recurrent ONNX operator.

## End-to-End Runtime Pipeline

```text
Accelerometer + gyroscope callbacks
    -> timestamp alignment and linear interpolation onto a 100 Hz grid
    -> 6-channel 100 Hz Butterworth high-pass filter
    -> tap_step.ms one-frame inference
    -> left/right alarm policy
    -> demo UI and haptic response
```

Relevant implementation files:

| File | Responsibility |
| --- | --- |
| `entry/src/main/ets/model/ImuStreamCollector.ets` | Collects accelerometer and gyroscope values, aligns timestamps, and emits ordered 100 Hz six-channel samples. |
| `entry/src/main/ets/model/TapPreprocessor.ets` | Training-equivalent high-pass filter and filter reset. |
| `entry/src/main/ets/model/TapDetector.ets` | Stateful MindSpore Lite inference, state feedback, input queue, and alarm policy. |
| `entry/src/main/ets/pages/DemoPage.ets` | Loads `tap_step.ms`, connects the IMU stream to `TapDetector`, and presents results. |
| `TapRecognition/tools/export_step_for_harmony.py` | Exports a trained checkpoint as a single-frame streaming ONNX graph. |
| `TapRecognition/tools/verify_harmony_lstm_step.py` | Checks full PyTorch, streaming PyTorch, ONNX Runtime, and MindSpore Lite outputs. |

## Model Tensor Contract

All current tensors are contiguous `float32`. MindSpore input and output ordering is positional in `TapDetector.ets`; preserve this order exactly.

| Position | Tensor | Shape | Meaning |
| --- | --- | --- | --- |
| Input 0 | `imu` | `[1, 1, 6]` | One preprocessed accelerometer/gyroscope sample. |
| Input 1 | `cnn_buffer` | `[1, 32, 29]` | Packed causal CNN input history. |
| Input 2 | `h_in` | `[1, 1, 64]` | LSTM hidden state for all layers. |
| Input 3 | `c_in` | `[1, 1, 64]` | LSTM cell state for all layers. |
| Output 0 | `prob` | `[1, 1, 3]` | Softmax probabilities in `(none, left, right)` order. |
| Output 1 | `h_out` | `[1, 1, 64]` | Updated hidden state. |
| Output 2 | `c_out` | `[1, 1, 64]` | Updated cell state. |
| Output 3 | `cnn_buffer_out` | `[1, 32, 29]` | Updated causal CNN history. |

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
- Reset the high-pass filter, CNN buffer, and recurrent states together at a real stream boundary by calling `TapDetector.reset()`.
- Every emitted frame must be processed in order. If frames are skipped, the filter, CNN, and LSTM histories no longer describe the same sequence.

`TapDetector.processSample()` uses a FIFO queue because `model.predict()` is asynchronous. Replacing the queue with a single "latest pending sample" slot would drop intermediate frames and corrupt state continuity under load.

## Alarm Policy

The model returns per-frame class probabilities. It does not emit an alarm itself. `TapDetector.ets` applies the product policy:

| Setting | Current value |
| --- | --- |
| Left threshold | `0.49` |
| Right threshold | `0.49` |
| Look-ahead | 12 frames, or 120 ms at 100 Hz |
| Refractory period | 50 frames, or 0.5 seconds |
| Refractory scope | Shared between left and right alarms |

On the first threshold crossing, the detector opens a 12-frame look-ahead window. It selects the highest eligible left/right probability in that window and emits the selected class after the window closes. Ties resolve to left because left is considered first. The refractory period begins from the selected peak, while also ensuring at least one frame after emission.

The `0.49/0.49` thresholds are a manual app setting requested for this demo. They are not the `max_f1 / lookahead_12f` selection stored with this checkpoint, which is `0.55/0.55`. Treat threshold changes as an operating-point decision and evaluate them on an appropriate validation or external set before shipping.

## Export a New LSTM Checkpoint

Run these commands from the `TapRecognition` training repository, not from this HarmonyOS project. A compatible checkpoint must contain `model_type`, `model_config`, and `model_state` and must have a correct causal `step()` implementation.

Set paths for the candidate checkpoint and temporary artifacts:

```bash
export CHECKPOINT='testing_checkpoints/(4)lstm64d8/best.pt'
export OUT_DIR=/tmp/tap_export
mkdir -p "$OUT_DIR"
```

Inspect the checkpoint configuration before changing the demo contract:

```bash
./.venv/bin/python -c "import torch; c=torch.load('$CHECKPOINT', map_location='cpu', weights_only=True); print(c['model_type']); print(c['model_config'])"
```

Export a single-frame ONNX graph. The exporter calls `model.eval()`, disables dropout, builds the zero states required by the checkpoint, and exports the correct input/output names for GRU or LSTM models.

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
  --inputShape='imu:1,1,6;cnn_buffer:1,32,29;h_in:1,1,64;c_in:1,1,64'
```

The output is `$OUT_DIR/tap_step.ms`. Converter success only means the file was produced. It does not prove that recurrent state or probabilities match PyTorch.

For a model with a different number of LSTM layers or hidden width, update the `h_in` and `c_in` dimensions in this command. For any other architecture change, derive all shapes from the exported ONNX graph and update the verifier and app together.

## Verify Numerical Equivalence

Use a left-tap recording, a right-tap recording, and a negative recording. Verify enough frames to exceed the CNN receptive field and preferably at least one long recording. The LSTM verifier currently supports the project's 6-input, 3-class, 32-CNN-channel, 64-hidden LSTM models with one or two layers.

```bash
./.venv/bin/python tools/verify_harmony_lstm_step.py \
  --checkpoint "$CHECKPOINT" \
  --onnx "$OUT_DIR/tap_step.onnx" \
  --ms "$OUT_DIR/tap_step.ms" \
  --runtime-lib "$MS_LITE_DIR/runtime/lib/libmindspore-lite.so" \
  --recording data/valid_data/imu_Miguel_knock_twice_left_20260921_175305.csv \
  --frames 600
```

Repeat with a right recording and a negative recording. For a longer-state check, the current artifact was also tested with:

```bash
./.venv/bin/python tools/verify_harmony_lstm_step.py \
  --checkpoint "$CHECKPOINT" \
  --onnx "$OUT_DIR/tap_step.onnx" \
  --ms "$OUT_DIR/tap_step.ms" \
  --runtime-lib "$MS_LITE_DIR/runtime/lib/libmindspore-lite.so" \
  --recording data/valid_data/imu_Miguel_shake_phone_20260921_172915.csv \
  --frames 1800
```

The verifier independently maintains PyTorch, ONNX Runtime, and MindSpore Lite CNN/LSTM states. It checks tensor names, order, sizes, absence of native recurrent ONNX operators, full-sequence PyTorch outputs, one-step PyTorch outputs, and the returned CNN/hidden/cell states. A passing result ends with `PASS`.

After copying the file into the demo, run the verifier once more against the bundled path. This catches a wrong copy or stale build artifact.

```bash
export DEMO_DIR=/path/to/TapRecognitionDemo

./.venv/bin/python tools/verify_harmony_lstm_step.py \
  --checkpoint "$CHECKPOINT" \
  --onnx "$OUT_DIR/tap_step.onnx" \
  --ms "$DEMO_DIR/entry/src/main/resources/rawfile/tap_step.ms" \
  --runtime-lib "$MS_LITE_DIR/runtime/lib/libmindspore-lite.so" \
  --recording data/valid_data/imu_Miguel_knock_twice_right_20260923_113004.csv \
  --frames 360
```

## Install a Verified Model

Copy only a verified `.ms` file, then record its checksum in the Current Artifact table.

```bash
cp "$OUT_DIR/tap_step.ms" \
  "$DEMO_DIR/entry/src/main/resources/rawfile/tap_step.ms"
sha256sum "$DEMO_DIR/entry/src/main/resources/rawfile/tap_step.ms"
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

Never update a model architecture by changing only `tap_step.ms`. The app intentionally checks the number of inputs, number of outputs, and returned tensor lengths to fail early on a mismatched artifact.

## Build and Device Validation

Open this project in DevEco Studio and install it on a phone after model verification. The entry module targets phones and declares accelerometer, gyroscope, vibration, and gesture-detection permissions. Gesture detection is used by the demo UI; the IMU classifier itself relies on accelerometer and gyroscope samples.

Perform physical testing after every model or preprocessing migration:

1. Confirm the model loads and the IMU stream starts.
2. Test left and right double taps in the intended device orientation and grip.
3. Test representative negative motion such as walking, shaking, handling, and screen interaction.
4. Check that the 120 ms look-ahead latency and 0.5 second shared refractory behavior are acceptable.
5. Capture and label new device recordings if the sensor axes, units, rate, or hardware differ from the training data.

The Linux C-runtime verifier validates the model file, but it does not validate HarmonyOS packaging, sensor calibration, permission behavior, or the device's real-time performance.

## Troubleshooting

| Symptom | Likely cause | Required action |
| --- | --- | --- |
| MindSpore model has three inputs when the app expects four | GRU/LSTM mismatch or wrong `.ms` file | Inspect checkpoint `model_type`; update the app and use the matching verifier. |
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

Keep this README's Current Artifact table and migration commands current whenever the model changes. The checksum, checkpoint configuration, converter version, numerical-verification result, preprocessing, and alarm policy are all part of one deployable model version.
