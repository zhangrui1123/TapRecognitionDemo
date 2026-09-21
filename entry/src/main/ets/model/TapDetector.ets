import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { TrainingHighPass } from './TapPreprocessor';
import { StreamImuSample } from './ImuStreamCollector';

const CNN_CHANNELS: number = 32;
const RECEPTIVE_FIELD: number = 29;
const GRU_HIDDEN: number = 64;
const GRU_LAYERS: number = 1;
const SAMPLE_RATE: number = 100.0;
const THRESHOLD_ON: number = 0.50;
const CONSECUTIVE_ON: number = 1;
const PEAK_CONFIRM_FRAMES: number = 4;
const LOOK_AHEAD_SEC: number = 0.12;
const REFRACTORY_SEC: number = 0.5;

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
  private cnnBuffer: Float32Array = new Float32Array(CNN_CHANNELS * RECEPTIVE_FIELD);
  private hState: Float32Array = new Float32Array(GRU_LAYERS * GRU_HIDDEN);
  private processing: boolean = false;
  private pendingSample: StreamImuSample | null = null;
  private onDetection: DetectionCallback | null = null;

  private consecutive: number = 0;
  private pendingStart: number = -1;
  private pendingBestP: number = 0;
  private pendingBestClass: number = 0;
  private framesSinceBest: number = 0;
  private latestClassId: number = 0;
  private emitClassId: number = 0;
  private refractoryUntil: number = 0;
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
    this.processing = false;
    this.pendingSample = null;
    this.consecutive = 0;
    this.pendingStart = -1;
    this.pendingBestP = 0;
    this.pendingBestClass = 0;
    this.framesSinceBest = 0;
    this.latestClassId = 0;
    this.emitClassId = 0;
    this.refractoryUntil = 0;
    this.frameIdx = 0;
  }

  async processSample(sample: StreamImuSample): Promise<void> {
    if (this.model === null) {
      return;
    }
    if (this.processing) {
      this.pendingSample = sample;
      return;
    }
    await this.runSample(sample);
    while (this.pendingSample !== null) {
      const next = this.pendingSample;
      this.pendingSample = null;
      await this.runSample(next);
    }
  }

  private async runSample(sample: StreamImuSample): Promise<void> {
    this.processing = true;
    const raw = new Float32Array([
      sample.accX,
      sample.accY,
      sample.accZ,
      sample.gyroX,
      sample.gyroY,
      sample.gyroZ,
    ]);
    const filtered = this.highPass.filter(raw);
    const timeSec = this.frameIdx / SAMPLE_RATE;
    this.frameIdx += 1;

    let probability = 0;
    let triggered = false;
    try {
      probability = await this.runStepInference(filtered);
      triggered = this.applyHysteresis(probability, timeSec);
    } catch (error) {
      console.error('TapDetector step inference failed:', JSON.stringify(error));
    } finally {
      this.processing = false;
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

  private async runStepInference(filtered: Float32Array): Promise<number> {
    const model = this.model;
    if (model === null) {
      return 0;
    }

    // Streaming model input: imu [1, 1, 6] — same 6 floats as training Butterworth output
    const imuStep = new Float32Array(6);
    for (let i = 0; i < 6; i++) {
      imuStep[i] = filtered[i];
    }

    const inputs = model.getInputs();
    inputs[0].setData(imuStep.buffer);
    inputs[1].setData(this.cnnBuffer.buffer);
    inputs[2].setData(this.hState.buffer);

    const outputs = await model.predict(inputs);
    const probData = new Float32Array(outputs[0].getData());

    this.hState = new Float32Array(outputs[1].getData());
    this.cnnBuffer = new Float32Array(outputs[2].getData());

    if (probData.length >= 3) {
      this.latestClassId = probData[1] >= probData[2] ? 1 : 2;
      return Math.max(probData[1], probData[2]);
    }
    this.latestClassId = 1;
    return probData[probData.length - 1];
  }

  private emitPending(timeSec: number): boolean {
    this.emitClassId = this.pendingBestClass;
    this.pendingStart = -1;
    this.pendingBestP = 0;
    this.pendingBestClass = 0;
    this.framesSinceBest = 0;
    this.consecutive = 0;
    this.refractoryUntil = timeSec + REFRACTORY_SEC;
    return true;
  }

  private applyHysteresis(probability: number, timeSec: number): boolean {
    if (this.pendingStart >= 0) {
      if (probability > this.pendingBestP) {
        this.pendingBestP = probability;
        this.pendingBestClass = this.latestClassId;
        this.framesSinceBest = 0;
      } else {
        this.framesSinceBest += 1;
      }
      const peaked = this.framesSinceBest >= PEAK_CONFIRM_FRAMES;
      const dropped = probability < THRESHOLD_ON;
      const timedOut = timeSec >= this.pendingStart + LOOK_AHEAD_SEC;
      if (peaked || dropped || timedOut) {
        return this.emitPending(timeSec);
      }
      return false;
    }

    if (timeSec < this.refractoryUntil) {
      return false;
    }

    if (probability >= THRESHOLD_ON) {
      this.consecutive += 1;
    } else {
      this.consecutive = 0;
    }

    if (this.consecutive >= CONSECUTIVE_ON) {
      this.pendingStart = timeSec - (CONSECUTIVE_ON - 1) / SAMPLE_RATE;
      this.pendingBestP = probability;
      this.pendingBestClass = this.latestClassId;
      this.framesSinceBest = 0;
    }

    return false;
  }
}
