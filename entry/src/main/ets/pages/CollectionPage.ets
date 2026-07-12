import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { CountdownRingView } from '../components/CountdownRingView';
import { ImuRecorder } from '../model/ImuRecorder';
import { saveCsvToFilesDir } from '../model/DataExporter';
import {
  ActionConfig,
  ACTION_WINDOW_SECONDS,
  findActionByType,
  SessionPhase,
  TOTAL_RECORD_SECONDS,
} from '../model/SessionTypes';

const TICK_MS: number = 50;

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
  private userName: string = '';
  private selectedAction: ActionConfig | undefined = undefined;
  private recorder: ImuRecorder = new ImuRecorder();
  private segmentTimer: number = -1;
  private sessionStarted: boolean = false;
  private remainingMs: number = ACTION_WINDOW_SECONDS * 1000;

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    this.userName = (params?.userName as string) ?? '';
    const actionType = (params?.actionType as string) ?? '';
    this.selectedAction = findActionByType(actionType);
    if (!this.selectedAction) {
      router.replaceUrl({ url: 'pages/Index' });
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
    this.statusHint = `第 ${this.segmentIndex} 段：请在 3 秒内完成「${this.selectedAction.label}」`;
    this.recorder.setPhase(SessionPhase.RECORDING, this.selectedAction.label, this.segmentIndex);

    this.clearTimer();
    this.segmentTimer = setInterval(() => {
      this.remainingMs -= TICK_MS;
      this.remainingRatio = Math.max(0, this.remainingMs / (ACTION_WINDOW_SECONDS * 1000));
      this.countdownValue = Math.max(1, Math.ceil(this.remainingMs / 1000));
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
    const actionTag = this.selectedAction?.type ?? 'unknown';
    const fileName =
      `imu_${this.userName}_${actionTag}_${timestamp.getFullYear()}${this.pad2(timestamp.getMonth() + 1)}` +
      `${this.pad2(timestamp.getDate())}_${this.pad2(timestamp.getHours())}${this.pad2(timestamp.getMinutes())}` +
      `${this.pad2(timestamp.getSeconds())}.csv`;
    const filePath = saveCsvToFilesDir(context.filesDir, fileName, this.recorder.getSamples());

    router.replaceUrl({
      url: 'pages/ResultPage',
      params: {
        userName: this.userName,
        actionLabel: this.currentActionLabel,
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

      Text('请在倒计时内完成动作')
        .fontSize(18)
        .fontColor($r('app.color.recording_color'))
        .margin({ bottom: 20 })

      CountdownRingView({
        remainingRatio: this.remainingRatio,
        countdownValue: this.countdownValue,
      })

      Text(`第 ${this.segmentIndex} 段`)
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

      Text(`总进度 ${this.displayElapsedSeconds}/${TOTAL_RECORD_SECONDS} 秒`)
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
