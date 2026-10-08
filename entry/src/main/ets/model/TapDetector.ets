import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { TrainingHighPass } from './TapPreprocessor';
import { StreamImuSample } from './ImuStreamCollector';
import { DEFAULT_TAP_MODEL, getTapModelProfile, TapModelProfile, TapModelVariant } from './TapModelProfiles';

const CNN_CHANNELS: number = 32;
const RECEPTIVE_FIELD: number = 29;
const LSTM_HIDDEN: number = 64;
const LSTM_LAYERS: number = 1;
const SAMPLE_RATE: number = 100.0;
const LOOK_AHEAD_FRAMES: number = 12;
const REFRACTORY_FRAMES: number = Math.round(0.5 * SAMPLE_RATE);
// A queue over one second means inference has already fallen out of real time.
// Resetting is safer than silently reporting old sensor data indefinitely.
const MAX_PENDING_SAMPLES: number = Math.round(1.0 * SAMPLE_RATE);

export interface DetectionResult {
  probability: number;
  triggered: boolean;
  frameIndex: number;
  classId: number;
}

export type DetectionCallback = (result: DetectionResult) => void;

export class TapDetector {
  private model: mindSporeLite.Model | null = null;
  // HarmonyOS Lite retains borrowed model storage (notably feature-graph constants).
  // Reclaiming this buffer caused delayed input-history corruption in device replay.
  // Keep it reachable for the native model's entire lifetime, including pause/reset.
  private modelBacking: ArrayBuffer | null = null;
  private highPass: TrainingHighPass = new TrainingHighPass();
  // tap_step.ms packs the input histories of the three CNN blocks (4 + 8 + 16)
  // into this buffer; its last slot is reserved. Reset all histories together.
  private cnnBuffer: Float32Array = new Float32Array(CNN_CHANNELS * RECEPTIVE_FIELD);
  private hState: Float32Array = new Float32Array(LSTM_LAYERS * LSTM_HIDDEN);
  private cState: Float32Array = new Float32Array(LSTM_LAYERS * LSTM_HIDDEN);
  private profile: TapModelProfile = getTapModelProfile(DEFAULT_TAP_MODEL);
  private featureHistory: Float32Array = new Float32Array(this.profile.featureHistoryFrames * 6);
  private featureReady: Float32Array = new Float32Array(1);
  private drainPromise: Promise<void> | null = null;
  private accepting: boolean = false;
  private generation: number = 0;
  private pendingSamples: StreamImuSample[] = [];
  private onDetection: DetectionCallback | null = null;

  private pendingStart: number = -1;
  private pendingBestP: number = -1;
  private pendingBestClass: number = 0;
  private pendingBestFrame: number = -1;
  private latestClassId: number = 0;
  private emitClassId: number = 0;
  private emitProbability: number = 0;
  private refractoryUntilFrame: number = 0;
  private frameIdx: number = 0;

  async loadModel(modelBuffer: ArrayBuffer, variant: TapModelVariant = DEFAULT_TAP_MODEL): Promise<void> {
    await this.pause();
    const profile = getTapModelProfile(variant);
    const context: mindSporeLite.Context = {
      target: ['cpu'],
      cpu: {
        threadNum: 1,
        threadAffinityMode: 1,
        precisionMode: 'enforce_fp32',
      },
    };
    const candidate = await mindSporeLite.loadModelFromBuffer(modelBuffer, context);
    const inputs = candidate.getInputs();
    const names: string[] = ['imu', 'cnn_buffer', 'h_in', 'c_in'];
    const shapes: number[][] = [[1, 1, 6], [1, 32, 29], [1, 1, 64], [1, 1, 64]];
    if (profile.featureHistoryFrames > 0) {
      names.push('feature_history', 'feature_ready');
      shapes.push([1, profile.featureHistoryFrames, 6], [1]);
    }
    if (inputs.length !== names.length) {
      throw new Error(`Expected ${names.length} inputs for ${profile.fileName}, got ${inputs.length}`);
    }
    for (let i = 0; i < inputs.length; i++) {
      if (inputs[i].name !== names[i] || inputs[i].shape.join(',') !== shapes[i].join(',')) {
        throw new Error(`Unexpected input contract at ${i} for ${profile.fileName}`);
      }
      inputs[i].setData(new Float32Array(inputs[i].elementNum).buffer);
    }
    // Validate outputs before activating; discard dry-run state and start cold.
    const outputs = await candidate.predict(inputs);
    this.validateOutputs(outputs, profile);
    this.model = candidate;
    this.modelBacking = modelBuffer;
    this.profile = profile;
    this.featureHistory = new Float32Array(profile.featureHistoryFrames * 6);
    this.reset();
  }

  isReady(): boolean {
    return this.model !== null;
  }

  setCallback(callback: DetectionCallback): void {
    this.onDetection = callback;
  }

  reset(): void {
    this.generation += 1;
    this.highPass.reset();
    this.cnnBuffer.fill(0);
    this.hState.fill(0);
    this.cState.fill(0);
    this.featureHistory.fill(0);
    this.featureReady.fill(0);
    this.accepting = this.model !== null;
    this.pendingSamples = [];
    this.pendingStart = -1;
    this.pendingBestP = -1;
    this.pendingBestClass = 0;
    this.pendingBestFrame = -1;
    this.latestClassId = 0;
    this.emitClassId = 0;
    this.emitProbability = 0;
    this.refractoryUntilFrame = 0;
    this.frameIdx = 0;
  }

  async pause(): Promise<void> {
    this.reset();
    this.accepting = false;
    const pending = this.drainPromise;
    if (pending !== null) {
      await pending;
    }
  }

  async processSample(sample: StreamImuSample): Promise<void> {
    if (this.model === null || !this.accepting) {
      return;
    }
    // Do not discard intermediate frames: the CNN buffer and LSTM hidden/cell states
    // depend on every sample in order, even while predict() is asynchronous.
    if (this.pendingSamples.length >= MAX_PENDING_SAMPLES) {
      this.reset();
    }
    this.pendingSamples.push(sample);
    if (this.drainPromise !== null) {
      return;
    }
    this.drainPromise = this.drainSamples();
    try {
      await this.drainPromise;
    } finally {
      this.drainPromise = null;
    }
  }

  private async drainSamples(): Promise<void> {
    while (this.pendingSamples.length > 0) {
      const next = this.pendingSamples.shift();
      if (next !== undefined) {
        await this.runSample(next);
      }
    }
  }

  private async runSample(sample: StreamImuSample): Promise<void> {
    const generation = this.generation;
    const raw = new Float32Array([
      sample.accX,
      sample.accY,
      sample.accZ,
      sample.gyroX,
      sample.gyroY,
      sample.gyroZ,
    ]);
    const filtered = this.highPass.filter(raw);
    this.frameIdx += 1;

    let probability = 0;
    let triggered = false;
    try {
      const probs = await this.runStepInference(filtered, generation);
      if (probs === null || generation !== this.generation) {
        return;
      }
      probability = Math.max(probs[1], probs[2]);
      this.latestClassId = probs[1] >= probs[2] ? 1 : 2;
      triggered = this.applyAlarmPolicy(probs[1], probs[2], this.frameIdx - 1);
      if (triggered) {
        probability = this.emitProbability;
      }
    } catch (error) {
      if (generation !== this.generation) {
        return;
      }
      console.error('TapDetector step inference failed:', JSON.stringify(error));
      // A failed frame is a discontinuity: never keep partially advanced state.
      this.reset();
      return;
    }

    if (this.onDetection) {
      this.onDetection({
        probability,
        triggered,
        frameIndex: this.frameIdx - 1,
        classId: triggered ? this.emitClassId : this.latestClassId,
      });
    }
  }

  private async runStepInference(filtered: Float32Array, generation: number): Promise<Float32Array | null> {
    const model = this.model;
    if (model === null) {
      throw new Error('Tap model not loaded');
    }

    // Streaming model input: imu [1, 1, 6] — same 6 floats as training Butterworth output
    const imuStep = new Float32Array(6);
    for (let i = 0; i < 6; i++) {
      imuStep[i] = filtered[i];
    }

    const inputs = model.getInputs();
    const hasFeatures = this.profile.featureHistoryFrames > 0;
    if (inputs.length !== (hasFeatures ? 6 : 4)) {
      throw new Error('Unexpected LSTM input count');
    }
    inputs[0].setData(imuStep.buffer);
    inputs[1].setData(this.cnnBuffer.buffer);
    inputs[2].setData(this.hState.buffer);
    inputs[3].setData(this.cState.buffer);
    if (hasFeatures) {
      inputs[4].setData(this.featureHistory.buffer);
      inputs[5].setData(this.featureReady.buffer);
    }

    const outputs = await model.predict(inputs);
    // reset(), pause(), or switching models must invalidate in-flight results.
    if (generation !== this.generation) {
      return null;
    }
    this.validateOutputs(outputs, this.profile);
    const probData = new Float32Array(outputs[0].getData());
    const nextH = new Float32Array(outputs[1].getData());
    const nextC = new Float32Array(outputs[2].getData());
    const nextBuffer = new Float32Array(outputs[3].getData());
    if (hasFeatures) {
      this.featureHistory = new Float32Array(outputs[4].getData()).slice();
      this.featureReady = new Float32Array(outputs[5].getData()).slice();
    }
    this.hState = nextH.slice();
    this.cState = nextC.slice();
    this.cnnBuffer = nextBuffer.slice();
    return probData;
  }

  private validateOutputs(outputs: mindSporeLite.MSTensor[], profile: TapModelProfile): void {
    const names: string[] = ['prob', 'h_out', 'c_out', 'cnn_buffer_out'];
    const lengths: number[] = [3, LSTM_LAYERS * LSTM_HIDDEN, LSTM_LAYERS * LSTM_HIDDEN,
      CNN_CHANNELS * RECEPTIVE_FIELD];
    if (profile.featureHistoryFrames > 0) {
      names.push('feature_history_out', 'feature_ready_out');
      lengths.push(profile.featureHistoryFrames * 6, 1);
    }
    if (outputs.length !== names.length) {
      throw new Error(`Unexpected output count for ${profile.fileName}`);
    }
    for (let i = 0; i < outputs.length; i++) {
      const values = new Float32Array(outputs[i].getData());
      if (outputs[i].name !== names[i] || values.length !== lengths[i]) {
        throw new Error(`Unexpected output contract at ${i} for ${profile.fileName}`);
      }
      for (let j = 0; j < values.length; j++) {
        if (!Number.isFinite(values[j])) {
          throw new Error(`Non-finite model output: ${names[i]}`);
        }
      }
    }
  }

  private considerCandidate(left: number, right: number, frame: number): void {
    // Same eligible-peak selection and tie order (left first) as offline
    // emit_alarms_pair: ineligible sides do not compete for the alarm.
    if (left >= this.profile.leftThreshold && left > this.pendingBestP) {
      this.pendingBestP = left;
      this.pendingBestClass = 1;
      this.pendingBestFrame = frame;
    }
    if (right >= this.profile.rightThreshold && right > this.pendingBestP) {
      this.pendingBestP = right;
      this.pendingBestClass = 2;
      this.pendingBestFrame = frame;
    }
  }

  private emitPending(frame: number): boolean {
    this.emitClassId = this.pendingBestClass;
    this.emitProbability = this.pendingBestP;
    // Shared refractory: resume at max(emission + 1, chosen peak + 50).
    this.refractoryUntilFrame = Math.max(frame + 1, this.pendingBestFrame + REFRACTORY_FRAMES);
    this.pendingStart = -1;
    this.pendingBestP = -1;
    this.pendingBestClass = 0;
    this.pendingBestFrame = -1;
    return true;
  }

  private applyAlarmPolicy(left: number, right: number, frame: number): boolean {
    if (this.pendingStart >= 0) {
      this.considerCandidate(left, right, frame);
      if (frame >= this.pendingStart + LOOK_AHEAD_FRAMES) {
        return this.emitPending(frame);
      }
      return false;
    }

    if (frame < this.refractoryUntilFrame) {
      return false;
    }

    if (left >= this.profile.leftThreshold || right >= this.profile.rightThreshold) {
      this.pendingStart = frame;
      this.considerCandidate(left, right, frame);
    }

    return false;
  }
}
