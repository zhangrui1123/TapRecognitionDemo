import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { TrainingHighPass } from './TapPreprocessor';
import { StreamImuSample } from './ImuStreamCollector';

const CNN_CHANNELS: number = 32;
const RECEPTIVE_FIELD: number = 29;
const GRU_HIDDEN: number = 64;
const GRU_LAYERS: number = 1;
const SAMPLE_RATE: number = 100.0;
/** Matches config/train.yaml prediction_threshold */
const THRESHOLD_ON: number = 0.7;
const THRESHOLD_OFF: number = 0.3;
const CONSECUTIVE_ON: number = 2;
const REFRACTORY_SEC: number = 0.5;

export interface DetectionResult {
  probability: number;
  triggered: boolean;
  frameIndex: number;
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
  private armed: boolean = false;
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
    this.armed = false;
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
      });
    }
  }

  private async runStepInference(filtered: Float32Array): Promise<number> {
    const model = this.model;
    if (model === null) {
      return 0;
    }

    const inputs = model.getInputs();
    inputs[0].setData(filtered.buffer);
    inputs[1].setData(this.cnnBuffer.buffer);
    inputs[2].setData(this.hState.buffer);

    const outputs = await model.predict(inputs);
    const logitData = new Float32Array(outputs[0].getData());
    const logit = logitData[logitData.length - 1];

    this.hState = new Float32Array(outputs[1].getData());
    this.cnnBuffer = new Float32Array(outputs[2].getData());

    return 1 / (1 + Math.exp(-logit));
  }

  private applyHysteresis(probability: number, timeSec: number): boolean {
    if (timeSec < this.refractoryUntil) {
      return false;
    }

    let triggered = false;
    if (probability >= THRESHOLD_ON) {
      this.consecutive += 1;
    } else {
      this.consecutive = 0;
    }

    if (this.consecutive >= CONSECUTIVE_ON && !this.armed) {
      triggered = true;
      this.armed = true;
      this.refractoryUntil = timeSec + REFRACTORY_SEC;
    }

    if (this.armed && probability < THRESHOLD_OFF) {
      this.armed = false;
      this.consecutive = 0;
    }

    return triggered;
  }
}
