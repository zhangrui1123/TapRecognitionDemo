import { common } from '@kit.AbilityKit';
import { ImuStreamCollector } from '../model/ImuStreamCollector';
import { TapDetector } from '../model/TapDetector';

@Entry
@Component
struct Index {
  @State isListening: boolean = false;
  @State isModelReady: boolean = false;
  @State modelError: ResourceStr = '';
  @State statusText: ResourceStr = $r('app.string.demo_hint');
  @State detectedText: ResourceStr = '';
  @State probability: number = 0;
  @State showDetection: boolean = false;
  @State detectionCount: number = 0;

  private imuCollector: ImuStreamCollector = new ImuStreamCollector();
  private tapDetector: TapDetector = new TapDetector();
  private hideDetectionTimer: number = -1;
  private uiContext: common.UIAbilityContext | null = null;

  aboutToAppear(): void {
    this.uiContext = getContext(this) as common.UIAbilityContext;
    this.statusText = $r('app.string.model_loading');
    this.loadModel();
  }

  aboutToDisappear(): void {
    this.stopListening();
    this.clearHideTimer();
  }

  private async loadModel(): Promise<void> {
    try {
      if (!this.uiContext) {
        throw new Error('UI context unavailable');
      }
      const modelBuffer = await this.uiContext.resourceManager.getRawFileContent('tap_step.ms');
      await this.tapDetector.loadModel(modelBuffer.buffer as ArrayBuffer);
      this.isModelReady = true;
      this.modelError = '';
      this.statusText = $r('app.string.demo_hint');
    } catch (error) {
      this.isModelReady = false;
      this.modelError = $r('app.string.model_error');
      this.statusText = $r('app.string.model_error');
      console.error('Failed to load tap model:', JSON.stringify(error));
    }
  }

  private startListening(): void {
    if (!this.isModelReady || this.isListening) {
      return;
    }

    this.tapDetector.reset();
    this.tapDetector.setCallback((result) => {
      this.probability = result.probability;
      if (result.triggered) {
        this.onDoubleTapDetected();
      }
    });

    this.detectedText = '';
    this.showDetection = false;
    this.probability = 0;
    this.detectionCount = 0;
    this.statusText = $r('app.string.listening');

    this.imuCollector.setCallback((sample) => {
      this.tapDetector.processSample(sample);
    });

    this.imuCollector.start().then(() => {
      this.isListening = true;
    }).catch((error: object) => {
      console.error('Failed to start IMU stream:', JSON.stringify(error));
      this.statusText = $r('app.string.model_error');
    });
  }

  private stopListening(): void {
    if (!this.isListening) {
      return;
    }
    this.imuCollector.stop();
    this.isListening = false;
    this.statusText = $r('app.string.demo_hint');
    this.probability = 0;
  }

  private onDoubleTapDetected(): void {
    this.detectionCount += 1;
    this.detectedText = $r('app.string.detected');
    this.showDetection = true;
    this.clearHideTimer();
    this.hideDetectionTimer = setTimeout(() => {
      this.showDetection = false;
      this.hideDetectionTimer = -1;
    }, 2000);
  }

  private clearHideTimer(): void {
    if (this.hideDetectionTimer >= 0) {
      clearTimeout(this.hideDetectionTimer);
      this.hideDetectionTimer = -1;
    }
  }

  build() {
    Column() {
      Text($r('app.string.demo_title'))
        .fontSize(32)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 72, bottom: 12 })

      Text(this.statusText)
        .fontSize(16)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: 48 })

      Stack() {
        Circle()
          .width(220)
          .height(220)
          .fill(this.showDetection ? '#E8F8EF' : '#EEF2F6')

        Column({ space: 8 }) {
          if (this.showDetection) {
            Text(this.detectedText)
              .fontSize(48)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.recording_color'))
          } else if (this.isListening) {
            Text('👂')
              .fontSize(56)
            Text($r('app.string.listening'))
              .fontSize(18)
              .fontColor($r('app.color.text_secondary'))
          } else {
            Text('📱')
              .fontSize(56)
            Text($r('app.string.demo_hint'))
              .fontSize(16)
              .fontColor($r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
              .width('80%')
          }
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
      .width(240)
      .height(240)
      .margin({ bottom: 32 })

      if (this.isListening) {
        Column({ space: 6 }) {
          Text(`置信度 ${(this.probability * 100).toFixed(0)}%`)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))

          if (this.detectionCount > 0) {
            Text(`已识别 ${this.detectionCount} 次`)
              .fontSize(13)
              .fontColor($r('app.color.recording_color'))
          }
        }
        .margin({ bottom: 24 })
      }

      if (this.modelError !== '') {
        Text(this.modelError)
          .fontSize(14)
          .fontColor('#D92D20')
          .margin({ bottom: 16 })
      }

      Blank()

      Button(this.isListening ? $r('app.string.stop_listening') : $r('app.string.start_listening'))
        .width('86%')
        .height(52)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .backgroundColor(this.isListening ? '#667085' : $r('app.color.primary_color'))
        .borderRadius(26)
        .enabled(this.isModelReady)
        .opacity(this.isModelReady ? 1 : 0.45)
        .margin({ bottom: 48 })
        .onClick(() => {
          if (this.isListening) {
            this.stopListening();
          } else {
            this.startListening();
          }
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .alignItems(HorizontalAlign.Center)
  }
}
