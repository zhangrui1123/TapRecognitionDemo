export enum ActionType {
  KNOCK_TWICE_LEFT = 'knock_twice_left',
  KNOCK_TWICE_RIGHT = 'knock_twice_right',
  KNOCK_ONCE = 'knock_once',
  ARBITRARY = 'arbitrary',
  ADJUST_GRIP = 'adjust_grip',
  SHAKE_PHONE = 'shake_phone',
  SWITCH_HAND = 'switch_hand',
  PICK_PLACE = 'pick_place',
}

export enum ScenarioCategory {
  POSITIVE = 'positive',
  NEGATIVE = 'negative',
}

export enum SessionPhase {
  COUNTDOWN = 'countdown',
  RECORDING = 'recording',
  FINISHED = 'finished',
}

export interface ActionConfig {
  type: ActionType;
  label: string;
  tag: string;
  category: ScenarioCategory;
}

/** 每段动作的采集窗口（倒计时即采集，无额外采集时长） */
export const ACTION_WINDOW_SECONDS: number = 3;
export const SEGMENT_RECORD_SECONDS: number = 0;
export const TOTAL_RECORD_SECONDS: number = 60;

/** IMU 固定采样率 100Hz，间隔 10ms */
export const SAMPLE_RATE_HZ: number = 100;
export const SAMPLE_INTERVAL_MS: number = 1000 / SAMPLE_RATE_HZ;
export const SAMPLE_INTERVAL_NS: number = SAMPLE_INTERVAL_MS * 1000000;

export const POSITIVE_ACTION_OPTIONS: ActionConfig[] = [
  {
    type: ActionType.KNOCK_TWICE_LEFT,
    label: '左侧敲一敲',
    tag: 'knock_twice_left',
    category: ScenarioCategory.POSITIVE,
  },
  {
    type: ActionType.KNOCK_TWICE_RIGHT,
    label: '右侧敲一敲',
    tag: 'knock_twice_right',
    category: ScenarioCategory.POSITIVE,
  },
];

export const NEGATIVE_ACTION_OPTIONS: ActionConfig[] = [
  {
    type: ActionType.KNOCK_ONCE,
    label: '敲一下',
    tag: 'knock_once',
    category: ScenarioCategory.NEGATIVE,
  },
  {
    type: ActionType.ARBITRARY,
    label: '任意动',
    tag: 'arbitrary',
    category: ScenarioCategory.NEGATIVE,
  },
  {
    type: ActionType.ADJUST_GRIP,
    label: '调整握姿',
    tag: 'adjust_grip',
    category: ScenarioCategory.NEGATIVE,
  },
  {
    type: ActionType.SHAKE_PHONE,
    label: '摇晃手机',
    tag: 'shake_phone',
    category: ScenarioCategory.NEGATIVE,
  },
  {
    type: ActionType.SWITCH_HAND,
    label: '换手',
    tag: 'switch_hand',
    category: ScenarioCategory.NEGATIVE,
  },
  {
    type: ActionType.PICK_PLACE,
    label: '拿放手机',
    tag: 'pick_place',
    category: ScenarioCategory.NEGATIVE,
  },
];

export const ACTION_OPTIONS: ActionConfig[] = [
  ...POSITIVE_ACTION_OPTIONS,
  ...NEGATIVE_ACTION_OPTIONS,
];

export function findActionByType(type: string): ActionConfig | undefined {
  return ACTION_OPTIONS.find((action: ActionConfig) => action.type === type);
}

/** Sanitize user input for English-only CSV file names. */
export function sanitizeFileNamePart(value: string): string {
  const sanitized = value.trim().replace(/[^a-zA-Z0-9_]/g, '_').replace(/_+/g, '_').replace(/^_|_$/g, '');
  return sanitized;
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
