import { sensor } from '@kit.SensorServiceKit';
import {
  interpolateAtTimestamp,
  normalizeTimestampNs,
  pushToRingBuffer,
  TimestampedVector,
} from './ImuAligner';
import { ImuSample, SAMPLE_INTERVAL_MS, SAMPLE_INTERVAL_NS, SessionPhase } from './SessionTypes';

const SENSOR_BUFFER_SIZE: number = 128;
/** 单次调度最多补发的网格样本数，避免定时器回调阻塞过久 */
const MAX_EMIT_PER_TICK: number = 8;

export class ImuRecorder {
  private accActive: boolean = false;
  private gyroActive: boolean = false;
  private accBuffer: TimestampedVector[] = [];
  private gyroBuffer: TimestampedVector[] = [];
  private samples: ImuSample[] = [];
  private userName: string = '';
  private currentPhase: SessionPhase = SessionPhase.COUNTDOWN;
  private currentActionLabel: string = '';
  private currentSegmentIndex: number = 0;
  private gridInitialized: boolean = false;
  private nextEmitTimestampNs: number = 0;
  private gridTimer: number = -1;

  setContext(userName: string): void {
    this.userName = userName;
  }

  setPhase(phase: SessionPhase, actionLabel: string, segmentIndex: number): void {
    this.currentPhase = phase;
    this.currentActionLabel = actionLabel;
    this.currentSegmentIndex = segmentIndex;
  }

  async start(): Promise<void> {
    this.accBuffer = [];
    this.gyroBuffer = [];
    this.gridInitialized = false;
    this.nextEmitTimestampNs = 0;
    await this.startGyroscope();
    await this.startAccelerometer();
    this.startGridTimer();
  }

  stop(): void {
    this.stopGridTimer();
    this.flushGridSamples();
    this.stopAccelerometer();
    this.stopGyroscope();
    this.accBuffer = [];
    this.gyroBuffer = [];
    this.gridInitialized = false;
  }

  getSamples(): ImuSample[] {
    return this.samples;
  }

  clearSamples(): void {
    this.samples = [];
  }

  /** 传感器回调：仅入缓冲，不做重采样 */
  private onAccCallback(data: sensor.AccelerometerResponse): void {
    pushToRingBuffer(this.accBuffer, {
      x: data.x,
      y: data.y,
      z: data.z,
      timestampNs: normalizeTimestampNs(data.timestamp),
    }, SENSOR_BUFFER_SIZE);
  }

  /** 传感器回调：仅入缓冲，不做重采样 */
  private onGyroCallback(data: sensor.GyroscopeResponse): void {
    pushToRingBuffer(this.gyroBuffer, {
      x: data.x,
      y: data.y,
      z: data.z,
      timestampNs: normalizeTimestampNs(data.timestamp),
    }, SENSOR_BUFFER_SIZE);
  }

  private startGridTimer(): void {
    if (this.gridTimer >= 0) {
      return;
    }
    this.gridTimer = setInterval(() => {
      this.tryEmitGridSamples();
    }, SAMPLE_INTERVAL_MS);
  }

  private stopGridTimer(): void {
    if (this.gridTimer < 0) {
      return;
    }
    clearInterval(this.gridTimer);
    this.gridTimer = -1;
  }

  private initGridIfNeeded(): void {
    if (this.gridInitialized || this.accBuffer.length === 0 || this.gyroBuffer.length === 0) {
      return;
    }
    const startNs = Math.max(this.accBuffer[0].timestampNs, this.gyroBuffer[0].timestampNs);
    this.nextEmitTimestampNs = Math.ceil(startNs / SAMPLE_INTERVAL_NS) * SAMPLE_INTERVAL_NS;
    this.gridInitialized = true;
  }

  /**
   * 独立 10ms 调度器：在均匀网格上对齐 acc/gyro 并出样。
   * 与传感器回调解耦，避免重采样逻辑阻塞 sensor.on。
   */
  private tryEmitGridSamples(): void {
    if (this.currentPhase !== SessionPhase.RECORDING) {
      return;
    }
    if (this.accBuffer.length < 2 || this.gyroBuffer.length < 2) {
      return;
    }

    this.initGridIfNeeded();
    if (!this.gridInitialized) {
      return;
    }

    const latestAccTs = this.accBuffer[this.accBuffer.length - 1].timestampNs;
    const latestGyroTs = this.gyroBuffer[this.gyroBuffer.length - 1].timestampNs;
    const safeUpperBound = Math.min(latestAccTs, latestGyroTs);

    let emitted = 0;
    while (this.nextEmitTimestampNs <= safeUpperBound && emitted < MAX_EMIT_PER_TICK) {
      this.emitAtGridTimestamp(this.nextEmitTimestampNs);
      this.nextEmitTimestampNs += SAMPLE_INTERVAL_NS;
      emitted += 1;
    }
  }

  private flushGridSamples(): void {
    if (!this.gridInitialized || this.currentPhase !== SessionPhase.RECORDING) {
      return;
    }
    if (this.accBuffer.length < 2 || this.gyroBuffer.length < 2) {
      return;
    }

    const latestAccTs = this.accBuffer[this.accBuffer.length - 1].timestampNs;
    const latestGyroTs = this.gyroBuffer[this.gyroBuffer.length - 1].timestampNs;
    const safeUpperBound = Math.min(latestAccTs, latestGyroTs);

    while (this.nextEmitTimestampNs <= safeUpperBound) {
      this.emitAtGridTimestamp(this.nextEmitTimestampNs);
      this.nextEmitTimestampNs += SAMPLE_INTERVAL_NS;
    }
  }

  private emitAtGridTimestamp(timestampNs: number): void {
    const acc = interpolateAtTimestamp(this.accBuffer, timestampNs);
    const gyro = interpolateAtTimestamp(this.gyroBuffer, timestampNs);
    if (!acc || !gyro) {
      return;
    }

    this.samples.push({
      timestampNs,
      userName: this.userName,
      phase: this.currentPhase,
      actionLabel: this.currentActionLabel,
      segmentIndex: this.currentSegmentIndex,
      accX: acc.x,
      accY: acc.y,
      accZ: acc.z,
      gyroX: gyro.x,
      gyroY: gyro.y,
      gyroZ: gyro.z,
    });
  }

  private async startAccelerometer(): Promise<void> {
    return new Promise((resolve, reject) => {
      try {
        sensor.on(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
          this.onAccCallback(data);
        }, { interval: SAMPLE_INTERVAL_NS });
        this.accActive = true;
        resolve();
      } catch (error) {
        reject(error);
      }
    });
  }

  private async startGyroscope(): Promise<void> {
    return new Promise((resolve, reject) => {
      try {
        sensor.on(sensor.SensorId.GYROSCOPE, (data: sensor.GyroscopeResponse) => {
          this.onGyroCallback(data);
        }, { interval: SAMPLE_INTERVAL_NS });
        this.gyroActive = true;
        resolve();
      } catch (error) {
        reject(error);
      }
    });
  }

  private stopAccelerometer(): void {
    if (!this.accActive) {
      return;
    }
    try {
      sensor.off(sensor.SensorId.ACCELEROMETER);
      this.accActive = false;
    } catch (error) {
      console.error('Failed to stop accelerometer:', JSON.stringify(error));
    }
  }

  private stopGyroscope(): void {
    if (!this.gyroActive) {
      return;
    }
    try {
      sensor.off(sensor.SensorId.GYROSCOPE);
      this.gyroActive = false;
    } catch (error) {
      console.error('Failed to stop gyroscope:', JSON.stringify(error));
    }
  }
}
