export enum TapModelVariant {
  Raw = 'raw',
  Features = 'features',
}

export interface TapModelProfile {
  variant: TapModelVariant;
  label: string;
  fileName: string;
  featureHistoryFrames: number;
  leftThreshold: number;
  rightThreshold: number;
}

// Change this single constant to Raw for a baseline-only default build.
export const DEFAULT_TAP_MODEL: TapModelVariant = TapModelVariant.Features;

export function getTapModelProfile(variant: TapModelVariant): TapModelProfile {
  if (variant === TapModelVariant.Raw) {
    return {
      variant: TapModelVariant.Raw,
      label: '原始 IMU · LSTM64',
      fileName: 'tap_step.ms',
      featureHistoryFrames: 0,
      leftThreshold: 0.65,
      rightThreshold: 0.51,
    };
  }
  return {
    variant: TapModelVariant.Features,
    label: '特征 IMU · d8(102)',
    fileName: 'tap_feature_step.ms',
    featureHistoryFrames: 14,
    // User-selected demo thresholds, shared with the raw profile.
    leftThreshold: 0.65,
    rightThreshold: 0.51,
  };
}
