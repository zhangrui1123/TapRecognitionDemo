import { sensor } from '@kit.SensorServiceKit';
import { normalizeTimestampNs } from './ImuAligner';
import { SAMPLE_INTERVAL_NS } from './SessionTypes';

export interface SensorCapabilityInfo {
  sensorName: string;
  vendorName: string;
  sensorId: number;
  minSamplePeriodNs: number;
  maxSamplePeriodNs: number;
}

export interface RateMeasureResult {
  sampleCount: number;
  durationMs: number;
  avgHz: number;
  avgIntervalMs: number;
  minIntervalMs: number;
  maxIntervalMs: number;
}

export function periodNsToHz(periodNs: number): number {
  if (periodNs <= 0) {
    return 0;
  }
  return 1000000000 / periodNs;
}

export function periodNsToMs(periodNs: number): number {
  return periodNs / 1000000;
}

export async function loadImuSensorCapabilities(): Promise<SensorCapabilityInfo[]> {
  const list = await sensor.getSensorList();
  return list.filter((item: sensor.Sensor) =>
    item.sensorId === sensor.SensorId.ACCELEROMETER ||
    item.sensorId === sensor.SensorId.GYROSCOPE
  ).map((item: sensor.Sensor): SensorCapabilityInfo => {
    const info: SensorCapabilityInfo = {
      sensorName: item.sensorName,
      vendorName: item.vendorName,
      sensorId: item.sensorId,
      minSamplePeriodNs: item.minSamplePeriod,
      maxSamplePeriodNs: item.maxSamplePeriod,
    };
    return info;
  });
}

export class SensorRateMeasurer {
  private accTimestamps: number[] = [];
  private gyroTimestamps: number[] = [];
  private accActive: boolean = false;
  private gyroActive: boolean = false;
  private startWallMs: number = 0;

  start(intervalNs: number = SAMPLE_INTERVAL_NS): void {
    this.accTimestamps = [];
    this.gyroTimestamps = [];
    this.startWallMs = Date.now();

    sensor.on(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
      this.accTimestamps.push(normalizeTimestampNs(data.timestamp));
    }, { interval: intervalNs });
    this.accActive = true;

    sensor.on(sensor.SensorId.GYROSCOPE, (data: sensor.GyroscopeResponse) => {
      this.gyroTimestamps.push(normalizeTimestampNs(data.timestamp));
    }, { interval: intervalNs });
    this.gyroActive = true;
  }

  stop(): void {
    if (this.accActive) {
      sensor.off(sensor.SensorId.ACCELEROMETER);
      this.accActive = false;
    }
    if (this.gyroActive) {
      sensor.off(sensor.SensorId.GYROSCOPE);
      this.gyroActive = false;
    }
  }

  buildResult(timestamps: number[]): RateMeasureResult {
    const durationMs = Math.max(1, Date.now() - this.startWallMs);
    if (timestamps.length < 2) {
      return {
        sampleCount: timestamps.length,
        durationMs,
        avgHz: timestamps.length > 0 ? (timestamps.length * 1000) / durationMs : 0,
        avgIntervalMs: 0,
        minIntervalMs: 0,
        maxIntervalMs: 0,
      };
    }

    const gapsMs: number[] = [];
    for (let i = 1; i < timestamps.length; i++) {
      gapsMs.push((timestamps[i] - timestamps[i - 1]) / 1000000);
    }

    const sumGap = gapsMs.reduce((sum: number, gap: number) => sum + gap, 0);
    return {
      sampleCount: timestamps.length,
      durationMs,
      avgHz: (timestamps.length * 1000) / durationMs,
      avgIntervalMs: sumGap / gapsMs.length,
      minIntervalMs: Math.min(...gapsMs),
      maxIntervalMs: Math.max(...gapsMs),
    };
  }

  getAccResult(): RateMeasureResult {
    return this.buildResult(this.accTimestamps);
  }

  getGyroResult(): RateMeasureResult {
    return this.buildResult(this.gyroTimestamps);
  }
}

export function formatRateResult(label: string, result: RateMeasureResult): string {
  if (result.sampleCount === 0) {
    return `${label}\n未收到数据`;
  }
  return `${label}
样本数: ${result.sampleCount}
时长: ${(result.durationMs / 1000).toFixed(1)} s
实测频率: ${result.avgHz.toFixed(1)} Hz
平均间隔: ${result.avgIntervalMs.toFixed(2)} ms
最小间隔: ${result.minIntervalMs.toFixed(2)} ms
最大间隔: ${result.maxIntervalMs.toFixed(2)} ms`;
}

export function formatCapability(info: SensorCapabilityInfo): string {
  const typeName = info.sensorId === sensor.SensorId.ACCELEROMETER ? '加速度计' : '陀螺仪';
  return `${typeName} (${info.sensorName})
厂商: ${info.vendorName}
最小周期: ${periodNsToMs(info.minSamplePeriodNs).toFixed(2)} ms (≈${periodNsToHz(info.minSamplePeriodNs).toFixed(1)} Hz)
最大周期: ${periodNsToMs(info.maxSamplePeriodNs).toFixed(2)} ms (≈${periodNsToHz(info.maxSamplePeriodNs).toFixed(1)} Hz)`;
}
