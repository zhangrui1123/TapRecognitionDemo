export interface TimestampedVector {
  x: number;
  y: number;
  z: number;
  timestampNs: number;
}

const MAX_SYNC_SKEW_NS: number = 20_000_000;

export function pushToRingBuffer(buffer: TimestampedVector[], sample: TimestampedVector, maxSize: number): void {
  buffer.push(sample);
  if (buffer.length > maxSize) {
    buffer.shift();
  }
}

/**
 * 在均匀时间网格上线性插值，acc/gyro 共用同一 target 时刻。
 * 用于固定 100Hz 重采样输出。
 */
export function interpolateAtTimestamp(buffer: TimestampedVector[], targetNs: number): TimestampedVector | null {
  if (buffer.length === 0) {
    return null;
  }

  let prev: TimestampedVector | undefined = undefined;
  let next: TimestampedVector | undefined = undefined;

  for (let i = 0; i < buffer.length; i++) {
    const sample = buffer[i];
    if (sample.timestampNs <= targetNs) {
      if (!prev || sample.timestampNs >= prev.timestampNs) {
        prev = sample;
      }
    }
    if (sample.timestampNs >= targetNs) {
      if (!next || sample.timestampNs <= next.timestampNs) {
        next = sample;
      }
    }
  }

  if (prev && prev.timestampNs === targetNs) {
    return {
      x: prev.x,
      y: prev.y,
      z: prev.z,
      timestampNs: targetNs,
    };
  }

  if (prev && next && next.timestampNs > prev.timestampNs) {
    const ratio = (targetNs - prev.timestampNs) / (next.timestampNs - prev.timestampNs);
    return {
      x: prev.x + ratio * (next.x - prev.x),
      y: prev.y + ratio * (next.y - prev.y),
      z: prev.z + ratio * (next.z - prev.z),
      timestampNs: targetNs,
    };
  }

  const nearest = prev ?? next;
  if (nearest && Math.abs(nearest.timestampNs - targetNs) <= MAX_SYNC_SKEW_NS) {
    return {
      x: nearest.x,
      y: nearest.y,
      z: nearest.z,
      timestampNs: targetNs,
    };
  }

  return null;
}

export function normalizeTimestampNs(timestamp: number | undefined): number {
  if (timestamp === undefined || timestamp <= 0) {
    return Date.now() * 1000000;
  }
  return timestamp;
}
