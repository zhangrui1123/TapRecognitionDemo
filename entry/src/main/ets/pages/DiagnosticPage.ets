import router from '@ohos.router';
import {
  formatCapability,
  formatRateResult,
  loadImuSensorCapabilities,
  periodNsToMs,
  SensorCapabilityInfo,
  SensorRateMeasurer,
} from '../model/SensorDiagnostics';
import { SAMPLE_INTERVAL_NS, SAMPLE_RATE_HZ } from '../model/SessionTypes';

const MEASURE_DURATION_MS: number = 3000;

@Entry
@Component
struct DiagnosticPage {
  @State capabilityText: string = '加载中…';
  @State accResultText: string = '尚未测试';
  @State gyroResultText: string = '尚未测试';
  @State statusHint: string = '查看硬件能力并实测回调频率';
  @State isMeasuring: boolean = false;
  @State requestedIntervalText: string =
    `当前请求: ${SAMPLE_RATE_HZ} Hz (${periodNsToMs(SAMPLE_INTERVAL_NS).toFixed(0)} ms / ${SAMPLE_INTERVAL_NS} ns)`;
  private measurer: SensorRateMeasurer = new SensorRateMeasurer();
  private measureTimer: number = -1;

  aboutToAppear(): void {
    this.loadCapabilities();
  }

  aboutToDisappear(): void {
    this.stopMeasure();
  }

  private async loadCapabilities(): Promise<void> {
    try {
      const capabilities = await loadImuSensorCapabilities();
      if (capabilities.length === 0) {
        this.capabilityText = '未找到加速度计或陀螺仪';
        return;
      }
      this.capabilityText = capabilities.map((item: SensorCapabilityInfo) => formatCapability(item)).join('\n\n');
    } catch (error) {
      this.capabilityText = `读取传感器信息失败: ${JSON.stringify(error)}`;
    }
  }

  private startMeasure(): void {
    if (this.isMeasuring) {
      return;
    }
    this.isMeasuring = true;
    this.accResultText = '测试中…';
    this.gyroResultText = '测试中…';
    this.statusHint = `正在实测 ${MEASURE_DURATION_MS / 1000} 秒，请保持应用在前台`;

    this.measurer.start(SAMPLE_INTERVAL_NS);
    this.measureTimer = setTimeout(() => {
      this.finishMeasure();
    }, MEASURE_DURATION_MS);
  }

  private finishMeasure(): void {
    this.measurer.stop();
    if (this.measureTimer >= 0) {
      clearTimeout(this.measureTimer);
      this.measureTimer = -1;
    }

    const accResult = this.measurer.getAccResult();
    const gyroResult = this.measurer.getGyroResult();
    this.accResultText = formatRateResult('【加速度计】', accResult);
    this.gyroResultText = formatRateResult('【陀螺仪】', gyroResult);
    this.isMeasuring = false;

    if (accResult.avgHz >= SAMPLE_RATE_HZ * 0.9) {
      this.statusHint = '实测频率接近 100Hz，硬件路径正常';
    } else if (accResult.avgHz >= 50) {
      this.statusHint = '实测频率低于 100Hz，可能存在系统限流；建议插电并开启性能模式';
    } else if (accResult.sampleCount === 0) {
      this.statusHint = '未收到传感器数据，请检查权限或设备';
    } else {
      this.statusHint = '实测频率明显偏低，采集时将依赖软件重采样补齐 100Hz';
    }
  }

  private stopMeasure(): void {
    this.measurer.stop();
    if (this.measureTimer >= 0) {
      clearTimeout(this.measureTimer);
      this.measureTimer = -1;
    }
    this.isMeasuring = false;
  }

  build() {
    Column() {
      Text('传感器诊断')
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 36, bottom: 8 })

      Text(this.statusHint)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: 16, left: 24, right: 24 })
        .textAlign(TextAlign.Center)

      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 8 }) {
            Text('硬件能力 (getSensorList)')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')

            Text(this.requestedIntervalText)
              .fontSize(13)
              .fontColor($r('app.color.primary_color'))
              .width('100%')

            Text(this.capabilityText)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .lineHeight(22)
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(12)

          Column({ space: 8 }) {
            Text('实测回调频率 (原始 sensor.on)')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')

            Text(this.accResultText)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .lineHeight(22)

            Text(this.gyroResultText)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .lineHeight(22)
          }
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(12)

          Column({ space: 6 }) {
            Text('建议')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')

            Text('1. 插电并开启性能/游戏模式后再测')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')

            Text('2. 若实测 < 100Hz，CSV 仍会通过网格重采样输出 10ms 间隔')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')

            Text('3. minSamplePeriod > 10ms 表示硬件上限低于 100Hz')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor('#EEF2F6')
          .borderRadius(12)
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 20 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      Button(this.isMeasuring ? '测试中…' : '开始 3 秒实测')
        .width('86%')
        .height(48)
        .fontSize(16)
        .backgroundColor($r('app.color.recording_color'))
        .borderRadius(24)
        .enabled(!this.isMeasuring)
        .opacity(this.isMeasuring ? 0.6 : 1)
        .margin({ top: 8, bottom: 12 })
        .onClick(() => {
          this.startMeasure();
        })

      Button($r('app.string.back_home'))
        .width('86%')
        .height(48)
        .fontSize(16)
        .backgroundColor($r('app.color.primary_color'))
        .borderRadius(24)
        .margin({ bottom: 36 })
        .onClick(() => {
          router.replaceUrl({ url: 'pages/Index' });
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .alignItems(HorizontalAlign.Center)
  }
}
