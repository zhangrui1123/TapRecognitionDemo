export enum ActionType {
  KNOCK_TWICE = 'knock_twice',
  KNOCK_ONCE = 'knock_once',
  ARBITRARY = 'arbitrary',
}

export enum SessionPhase {
  COUNTDOWN = 'countdown',
  RECORDING = 'recording',
  FINISHED = 'finished',
}

export interface ActionConfig {
  type: ActionType;
  label: string;
}

/** 每段动作的采集窗口（倒计时即采集，无额外采集时长） */
export const ACTION_WINDOW_SECONDS: number = 3;
export const SEGMENT_RECORD_SECONDS: number = 0;
export const TOTAL_RECORD_SECONDS: number = 60;

/** IMU 固定采样率 100Hz，间隔 10ms */
export const SAMPLE_RATE_HZ: number = 100;
export const SAMPLE_INTERVAL_MS: number = 1000 / SAMPLE_RATE_HZ;
export const SAMPLE_INTERVAL_NS: number = SAMPLE_INTERVAL_MS * 1000000;

export const ACTION_OPTIONS: ActionConfig[] = [
  { type: ActionType.KNOCK_TWICE, label: '敲一敲' },
  { type: ActionType.KNOCK_ONCE, label: '敲一下' },
  { type: ActionType.ARBITRARY, label: '任意动' },
];

export function findActionByType(type: string): ActionConfig | undefined {
  return ACTION_OPTIONS.find((action: ActionConfig) => action.type === type);
}

export interface ImuSample {
  timestampNs: number;
  userName: string;
  phase: SessionPhase;
  actionLabel: string;
  segmentIndex: number;
  accX: number;
  accY: number;
  accZ: number;
  gyroX: number;
  gyroY: number;
  gyroZ: number;
}
