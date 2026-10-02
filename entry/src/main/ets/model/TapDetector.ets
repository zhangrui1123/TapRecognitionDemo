import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { TrainingHighPass } from './TapPreprocessor';
import { StreamImuSample } from './ImuStreamCollector';

const CNN_CHANNELS: number = 32;
const RECEPTIVE_FIELD: number = 29;
const LSTM_HIDDEN: number = 64;
const LSTM_LAYERS: number = 1;
const SAMPLE_RATE: number = 100.0;
// User-selected thresholds for (4)lstm64d8; retain the 12-frame alarm policy.
const LEFT_THRESHOLD: number = 0.49;
const RIGHT_THRESHOLD: number = 0.49;
const LOOK_AHEAD_FRAMES: number = 12;
const REFRACTORY_FRAMES: number = Math.round(0.5 * SAMPLE_RATE);

export interface DetectionResult {
  probability: number;
  triggered: boolean;
  frameIndex: number;
  classId: number;
}

export type DetectionCallback = (result: DetectionResult) => void;

export class TapDetector {
  private model: mindSporeLite.Model | null = null;
  private highPass: TrainingHighPass = new TrainingHighPass();
  // tap_step.ms packs the input histories of the three CNN blocks (4 + 8 + 16)
  // into this buffer; its last slot is reserved. Reset all histories together.
  private cnnBuffer: Float32Array = new Float32Array(CNN_CHANNELS * RECEPTIVE_FIELD);
  private hState: Float32Array = new Float32Array(LSTM_LAYERS * LSTM_HIDDEN);
  private cState: Float32Array = new Float32Array(LSTM_LAYERS * LSTM_HIDDEN);
  private draining: boolean = false;
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

  async loadModel(modelBuffer: ArrayBuffer): Promise<void> {
    const context: mindSporeLite.Context = {
      target: ['cpu'],
      cpu: {
        threadNum: 1,
        threadAffinityMode: 1,
        precisionMode: 'enforce_fp32',
      },
    };
    this.model = await mindSporeLite.loadModelFromBuffer(modelBuffer, context);
  }

  isReady(): boolean {
    return this.model !== null;
  }

  setCallback(callback: DetectionCallback): void {
    this.onDetection = callback;
  }

  reset(): void {
    this.highPass.reset();
    this.cnnBuffer.fill(0);
    this.hState.fill(0);
    this.cState.fill(0);
    this.draining = false;
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

  async processSample(sample: StreamImuSample): Promise<void> {
    if (this.model === null) {
      return;
    }
    // Do not discard intermediate frames: the CNN buffer and LSTM hidden/cell states
    // depend on every sample in order, even while predict() is asynchronous.
    this.pendingSamples.push(sample);
    if (this.draining) {
      return;
    }
    this.draining = true;
    try {
      while (this.pendingSamples.length > 0) {
        const next = this.pendingSamples.shift();
        if (next !== undefined) {
          await this.runSample(next);
        }
      }
    } finally {
      this.draining = false;
    }
  }

  private async runSample(sample: StreamImuSample): Promise<void> {
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
      const probs = await this.runStepInference(filtered);
      probability = Math.max(probs[1], probs[2]);
      this.latestClassId = probs[1] >= probs[2] ? 1 : 2;
      triggered = this.applyAlarmPolicy(probs[1], probs[2], this.frameIdx - 1);
      if (triggered) {
        probability = this.emitProbability;
      }
    } catch (error) {
      console.error('TapDetector step inference failed:', JSON.stringify(error));
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

  private async runStepInference(filtered: Float32Array): Promise<Float32Array> {
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
    if (inputs.length !== 4) {
      throw new Error(`Expected 4 LSTM inputs, got ${inputs.length}`);
    }
    inputs[0].setData(imuStep.buffer);
    inputs[1].setData(this.cnnBuffer.buffer);
    inputs[2].setData(this.hState.buffer);
    inputs[3].setData(this.cState.buffer);

    const outputs = await model.predict(inputs);
    if (outputs.length !== 4) {
      throw new Error(`Expected 4 LSTM outputs, got ${outputs.length}`);
    }
    const probData = new Float32Array(outputs[0].getData());
    const nextH = new Float32Array(outputs[1].getData());
    const nextC = new Float32Array(outputs[2].getData());
    const nextBuffer = new Float32Array(outputs[3].getData());
    if (probData.length !== 3 || nextH.length !== LSTM_LAYERS * LSTM_HIDDEN ||
      nextC.length !== LSTM_LAYERS * LSTM_HIDDEN || nextBuffer.length !== CNN_CHANNELS * RECEPTIVE_FIELD) {
      throw new Error('Unexpected LSTM output tensor shapes');
    }
    this.hState = nextH;
    this.cState = nextC;
    this.cnnBuffer = nextBuffer;
    return probData;
  }

  private considerCandidate(left: number, right: number, frame: number): void {
    // Same eligible-peak selection and tie order (left first) as offline
    // emit_alarms_pair: ineligible sides do not compete for the alarm.
    if (left >= LEFT_THRESHOLD && left > this.pendingBestP) {
      this.pendingBestP = left;
      this.pendingBestClass = 1;
      this.pendingBestFrame = frame;
    }
    if (right >= RIGHT_THRESHOLD && right > this.pendingBestP) {
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

    if (left >= LEFT_THRESHOLD || right >= RIGHT_THRESHOLD) {
      this.pendingStart = frame;
      this.considerCandidate(left, right, frame);
    }

    return false;
  }
}
