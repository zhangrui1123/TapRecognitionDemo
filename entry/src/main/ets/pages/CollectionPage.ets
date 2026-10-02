import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { CountdownRingView } from '../components/CountdownRingView';
import { ImuRecorder } from '../model/ImuRecorder';
import { saveCsvToFilesDir } from '../model/DataExporter';
import {
  ActionConfig,
  ActionType,
  ACTION_WINDOW_SECONDS,
  findActionByType,
  sanitizeFileNamePart,
  SessionPhase,
  TOTAL_RECORD_SECONDS,
} from '../model/SessionTypes';

const TICK_MS: number = 50;
const STRICT_PREPARE_MS: number = 1900;
const STRICT_SECOND_TAP_MS: number = 2000;
const STRICT_WAIT_COLOR: string = '#D92D20';
const STRICT_PREPARE_COLOR: string = '#FF6B00';
const STRICT_TAP_COLOR: string = '#00B578';

@Entry
@Component
struct CollectionPage {
  @State countdownValue: number = ACTION_WINDOW_SECONDS;
  @State remainingRatio: number = 1;
  @State segmentIndex: number = 1;
  @State displayElapsedSeconds: number = 0;
  @State totalRecordedSeconds: number = 0;
  @State statusHint: string = '请准备';
  @State currentActionLabel: string = '';
  @State strictRingColor: string = STRICT_WAIT_COLOR;
  private userName: string = '';
  private selectedAction: ActionConfig | undefined = undefined;
  private strictSecondTap: boolean = false;
  private recorder: ImuRecorder = new ImuRecorder();
  private segmentTimer: number = -1;
  private sessionStarted: boolean = false;
  private remainingMs: number = ACTION_WINDOW_SECONDS * 1000;
  private segmentStartMs: number = 0;

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    this.userName = sanitizeFileNamePart((params?.userName as string) ?? '');
    const actionType = (params?.actionType as string) ?? '';
    this.selectedAction = findActionByType(actionType);
    this.strictSecondTap = (params?.strictSecondTap as boolean) === true &&
      (this.selectedAction?.type === ActionType.KNOCK_TWICE_LEFT ||
        this.selectedAction?.type === ActionType.KNOCK_TWICE_RIGHT);
    if (this.userName.length === 0 || !this.selectedAction) {
      router.replaceUrl({ url: 'pages/CollectionSetupPage' });
      return;
    }
    this.currentActionLabel = this.selectedAction.label;
    this.recorder.setContext(this.userName);
    this.startSession();
  }

  aboutToDisappear(): void {
    this.clearTimer();
    this.recorder.stop();
  }

  private clearTimer(): void {
    if (this.segmentTimer >= 0) {
      clearInterval(this.segmentTimer);
      this.segmentTimer = -1;
    }
  }

  private async startSession(): Promise<void> {
    if (this.sessionStarted || !this.selectedAction) {
      return;
    }
    this.sessionStarted = true;
    try {
      await this.recorder.start();
      this.beginSegment();
    } catch (error) {
      console.error('Failed to start IMU sensors:', JSON.stringify(error));
      this.finishSession();
    }
  }

  private beginSegment(): void {
    if (!this.selectedAction) {
      return;
    }

    const remainingSeconds = TOTAL_RECORD_SECONDS - this.totalRecordedSeconds;
    if (remainingSeconds <= 0) {
      this.finishSession();
      return;
    }

    this.remainingMs = ACTION_WINDOW_SECONDS * 1000;
    this.countdownValue = ACTION_WINDOW_SECONDS;
    this.remainingRatio = 1;
    this.strictRingColor = STRICT_WAIT_COLOR;
    this.statusHint = this.strictSecondTap
      ? `Segment ${this.segmentIndex}: First tap before 2 s; wait for green for the second tap.`
      : `第 ${this.segmentIndex} 段：请在 3 秒内完成「${this.selectedAction.label}」`;
    this.segmentStartMs = Date.now();
    this.recorder.setPhase(SessionPhase.RECORDING, this.selectedAction.tag, this.segmentIndex);

    this.clearTimer();
    this.segmentTimer = setInterval(() => {
      const elapsedMs = Math.max(0, Date.now() - this.segmentStartMs);
      this.remainingMs = Math.max(0, ACTION_WINDOW_SECONDS * 1000 - elapsedMs);
      this.remainingRatio = Math.max(0, this.remainingMs / (ACTION_WINDOW_SECONDS * 1000));
      this.countdownValue = Math.max(1, Math.ceil(this.remainingMs / 1000));
      if (this.strictSecondTap) {
        this.updateStrictCue(elapsedMs);
      }
      this.syncDisplayElapsed();

      if (this.remainingMs <= 0) {
        this.remainingRatio = 0;
        this.countdownValue = 0;
        this.syncDisplayElapsed();
        clearInterval(this.segmentTimer);
        this.segmentTimer = -1;
        this.totalRecordedSeconds += ACTION_WINDOW_SECONDS;
        this.onSegmentFinished();
      }
    }, TICK_MS);
  }

  private updateStrictCue(elapsedMs: number): void {
    if (elapsedMs >= STRICT_SECOND_TAP_MS && this.strictRingColor !== STRICT_TAP_COLOR) {
      this.strictRingColor = STRICT_TAP_COLOR;
      this.statusHint = `Segment ${this.segmentIndex}: Second tap now, before the segment ends!`;
    } else if (elapsedMs >= STRICT_PREPARE_MS && elapsedMs < STRICT_SECOND_TAP_MS &&
      this.strictRingColor !== STRICT_PREPARE_COLOR) {
      this.strictRingColor = STRICT_PREPARE_COLOR;
      this.statusHint = `Segment ${this.segmentIndex}: Get ready for the second tap.`;
    }
  }

  private syncDisplayElapsed(): void {
    const segmentElapsed = Math.floor((ACTION_WINDOW_SECONDS * 1000 - this.remainingMs) / 1000);
    const elapsed = Math.min(
      TOTAL_RECORD_SECONDS,
      (this.segmentIndex - 1) * ACTION_WINDOW_SECONDS + segmentElapsed
    );
    if (elapsed !== this.displayElapsedSeconds) {
      this.displayElapsedSeconds = elapsed;
    }
  }

  private onSegmentFinished(): void {
    if (!this.selectedAction) {
      return;
    }

    if (this.totalRecordedSeconds >= TOTAL_RECORD_SECONDS) {
      this.finishSession();
      return;
    }

    this.segmentIndex += 1;
    this.beginSegment();
  }

  private finishSession(): void {
    this.clearTimer();
    this.recorder.stop();

    const context = getContext(this) as common.UIAbilityContext;
    const timestamp = new Date();
    const actionTag = this.selectedAction?.tag ?? 'unknown';
    const collectorId = sanitizeFileNamePart(this.userName);
    const filePrefix = this.strictSecondTap ? 'imuStrict' : 'imu';
    const fileName =
      `${filePrefix}_${collectorId}_${actionTag}_${timestamp.getFullYear()}${this.pad2(timestamp.getMonth() + 1)}` +
      `${this.pad2(timestamp.getDate())}_${this.pad2(timestamp.getHours())}${this.pad2(timestamp.getMinutes())}` +
      `${this.pad2(timestamp.getSeconds())}.csv`;
    const filePath = saveCsvToFilesDir(context.filesDir, fileName, this.recorder.getSamples());

    router.replaceUrl({
      url: 'pages/ResultPage',
      params: {
        userName: this.userName,
        actionLabel: this.selectedAction?.tag ?? this.currentActionLabel,
        sampleCount: this.recorder.getSamples().length,
        filePath,
      },
    });
  }

  private pad2(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  build() {
    Column() {
      Text(this.userName)
        .fontSize(16)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 40, bottom: 8 })

      Text(this.currentActionLabel)
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.primary_color'))
        .margin({ bottom: 16 })

      Text(this.strictSecondTap ? 'Second tap after 2 s, before 3 s' : '请在倒计时内完成动作')
        .fontSize(18)
        .fontColor(this.strictSecondTap ? this.strictRingColor : $r('app.color.recording_color'))
        .margin({ bottom: 20 })

      CountdownRingView({
        remainingRatio: this.remainingRatio,
        countdownValue: this.countdownValue,
        countdownColor: this.strictSecondTap ? this.strictRingColor : $r('app.color.countdown_color'),
        unitLabel: this.strictSecondTap ? 's' : '秒',
      })

      Text(this.strictSecondTap ? `Segment ${this.segmentIndex}` : `第 ${this.segmentIndex} 段`)
        .fontSize(22)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 12 })

      Text(this.statusHint)
        .fontSize(16)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 24 })
        .padding({ left: 24, right: 24 })
        .textAlign(TextAlign.Center)

      Progress({
        value: this.displayElapsedSeconds,
        total: TOTAL_RECORD_SECONDS,
        type: ProgressType.Linear,
      })
        .width('84%')
        .margin({ top: 40 })

      Text(this.strictSecondTap
        ? `Total progress ${this.displayElapsedSeconds}/${TOTAL_RECORD_SECONDS} s`
        : `总进度 ${this.displayElapsedSeconds}/${TOTAL_RECORD_SECONDS} 秒`)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 12 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .alignItems(HorizontalAlign.Center)
  }
}
