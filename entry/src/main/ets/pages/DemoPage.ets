/**
 * SideTap-style demo: full-screen Xiaohongshu post + side-tap shrink to reveal assistant panel.
 * Interaction aligned with SideTap: grip-aware shrink, edge drag/double-tap, haptic, edge flow.
 */
import router from '@ohos.router';
import { common, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { motion } from '@kit.MultimodalAwarenessKit';
import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { display, curves } from '@kit.ArkUI';
import { hdsEffect } from '@kit.UIDesignKit';
import { KyotoPost } from '../components/KyotoPost';
import { FlowEffects } from '../effects/FlowEffects';
import { ImuStreamCollector } from '../model/ImuStreamCollector';
import { TapDetector } from '../model/TapDetector';
import { DEFAULT_TAP_MODEL, getTapModelProfile, TapModelVariant } from '../model/TapModelProfiles';

@Entry
@Component
struct DemoPage {
  private imuCollector: ImuStreamCollector = new ImuStreamCollector();
  private tapDetector: TapDetector = new TapDetector();
  private uiContext: common.UIAbilityContext | null = null;
  private knockLockTimerId: number = -1;
  private toastTimerId: number = -1;
  private panStartProgress: number = 0;
  private panEnabled: boolean = false;
  private gripCallback: ((data: motion.HoldingHandStatus) => void) | null = null;
  private gripSubscribed: boolean = false;
  private clockTimer: number = -1;
  private controller: hdsEffect.ShaderEffectController | undefined = undefined;
  private flowEffect: VisualEffect | undefined = undefined;
  private pageActive: boolean = false;
  private detectionGeneration: number = 0;
  private sensorStart: Promise<void> | null = null;
  private probabilityTimes: number[] = [];
  private probabilityValues: number[] = [];

  private readonly KNOCK_LOCK_DURATION: number = 500;
  private readonly SHRINK_RATIO: number = 1 / 3;
  private readonly CORNER_RADIUS: number = 32;
  private readonly STATUS_BAR_HEIGHT: number = 44;
  private readonly CAMERA_INSET: number = 50;
  private readonly PROBABILITY_WINDOW_MS: number = 150;

  @State private modelReady: boolean = false;
  @State private modelVariant: TapModelVariant = DEFAULT_TAP_MODEL;
  @State private modelSwitching: boolean = false;
  @State private modelError: ResourceStr = '';
  @State private isDetecting: boolean = false;
  @State private probability: number = 0;
  @State private detectionCount: number = 0;
  @State private lastDetectionLabel: string = '';
  @State private shrinkProgress: number = 0;
  @State private isShrunk: boolean = false;
  @State private isKnocking: boolean = false;
  @State private gripHand: string = 'right';
  @State private gripGranted: boolean = false;
  @State private screenWidthVp: number = 360;
  @State private screenHeightVp: number = 780;
  @State private clock: string = '';
  @State private debugVisible: boolean = false;
  @State private flowReady: boolean = false;
  @State private toastText: string = '';
  @State private toastVisible: boolean = false;
  @State private edgeHintOpacity: number = 0.55;

  async aboutToAppear(): Promise<void> {
    this.pageActive = true;
    this.uiContext = getContext(this) as common.UIAbilityContext;
    this.initFlowEffect();
    try {
      const d = display.getDefaultDisplaySync();
      this.screenWidthVp = px2vp(d.width);
      this.screenHeightVp = px2vp(d.height);
    } catch (_e) {
    }
    this.updateClock();
    this.clockTimer = setInterval(() => this.updateClock(), 20000);
    await this.loadModel();
    this.startGripDetection();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.stopDetection();
    this.stopGripDetection();
    if (this.clockTimer !== -1) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
    if (this.knockLockTimerId !== -1) {
      clearTimeout(this.knockLockTimerId);
      this.knockLockTimerId = -1;
    }
    if (this.toastTimerId !== -1) {
      clearTimeout(this.toastTimerId);
      this.toastTimerId = -1;
    }
  }

  private initFlowEffect(): void {
    try {
      this.controller = new hdsEffect.ShaderEffectController();
      this.flowEffect = FlowEffects.edgeFlow(this.controller);
      this.flowReady = true;
    } catch (_e) {
      this.flowReady = false;
    }
  }

  private updateClock(): void {
    const d = new Date();
    const hh = d.getHours();
    const mm = d.getMinutes();
    this.clock = (hh < 10 ? `0${hh}` : `${hh}`) + ':' + (mm < 10 ? `0${mm}` : `${mm}`);
  }

  private async loadModel(variant: TapModelVariant = this.modelVariant): Promise<void> {
    if (this.modelSwitching) {
      return;
    }
    this.modelSwitching = true;
    this.modelReady = false;
    try {
      this.stopDetection();
      // A start can still be between the gyro and accelerometer subscriptions.
      // Wait for it to finish stopping before starting the replacement stream.
      const starting = this.sensorStart;
      if (starting !== null) {
        await starting;
      }
      await this.tapDetector.pause();
      this.modelVariant = variant;
      if (!this.uiContext) {
        throw new Error('UI context unavailable');
      }
      const profile = getTapModelProfile(this.modelVariant);
      const modelBuffer = await this.uiContext.resourceManager.getRawFileContent(profile.fileName);
      await this.tapDetector.loadModel(modelBuffer.buffer as ArrayBuffer, this.modelVariant);
      this.modelReady = true;
      this.modelError = '';
      if (this.pageActive) {
        this.startDetection();
      } else {
        await this.tapDetector.pause();
      }
    } catch (error) {
      this.modelReady = false;
      this.modelError = $r('app.string.model_error');
      console.error('Failed to load tap model:', JSON.stringify(error));
    } finally {
      this.modelSwitching = false;
    }
  }

  private async switchModel(): Promise<void> {
    if (this.modelSwitching) {
      return;
    }
    this.detectionCount = 0;
    this.lastDetectionLabel = '';
    const variant = this.modelVariant === TapModelVariant.Features ? TapModelVariant.Raw : TapModelVariant.Features;
    await this.loadModel(variant);
  }

  private startDetection(): void {
    if (!this.modelReady || this.isDetecting) {
      return;
    }
    this.tapDetector.reset();
    this.probabilityTimes = [];
    this.probabilityValues = [];
    const generation = ++this.detectionGeneration;
    this.tapDetector.setCallback((result) => {
      this.updateProbabilityPeak(result.probability);
      if (result.triggered) {
        const hand = result.classId === 2 ? 'right' : 'left';
        const label = result.classId === 2 ? '右敲' : '左敲';
        this.lastDetectionLabel = label;
        this.detectionCount += 1;
        this.showToast(`${label} · ${(result.probability * 100).toFixed(0)}%`);
        this.triggerKnock(hand);
      }
    });
    this.imuCollector.setCallback((sample) => {
      this.tapDetector.processSample(sample);
    });
    this.sensorStart = this.imuCollector.start().then(() => {
      if (this.pageActive && generation === this.detectionGeneration) {
        this.isDetecting = true;
      } else {
        this.imuCollector.stop();
        this.tapDetector.pause();
      }
    }).catch((error: object) => {
      this.imuCollector.stop();
      this.tapDetector.pause();
      console.error('Failed to start IMU stream:', JSON.stringify(error));
    }).finally(() => {
      this.sensorStart = null;
    });
  }

  private stopDetection(): void {
    this.detectionGeneration += 1;
    this.tapDetector.pause();
    this.imuCollector.stop();
    this.isDetecting = false;
    this.probability = 0;
    this.probabilityTimes = [];
    this.probabilityValues = [];
  }

  private updateProbabilityPeak(probability: number): void {
    const now = Date.now();
    this.probabilityTimes.push(now);
    this.probabilityValues.push(probability);
    while (this.probabilityTimes.length > 0 && this.probabilityTimes[0] < now - this.PROBABILITY_WINDOW_MS) {
      this.probabilityTimes.shift();
      this.probabilityValues.shift();
    }
    this.probability = Math.max(...this.probabilityValues);
  }

  private showToast(text: string): void {
    this.toastText = text;
    this.toastVisible = true;
    if (this.toastTimerId !== -1) {
      clearTimeout(this.toastTimerId);
    }
    this.toastTimerId = setTimeout(() => {
      this.toastVisible = false;
      this.toastTimerId = -1;
    }, 1200);
  }

  private async startGripDetection(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const atm = abilityAccessCtrl.createAtManager();
      const perm: Permissions = 'ohos.permission.DETECT_GESTURE';
      const res = await atm.requestPermissionsFromUser(ctx, [perm]);
      this.gripGranted = res.authResults[0] === 0;
      if (!this.gripGranted) {
        return;
      }
      this.gripCallback = (data: motion.HoldingHandStatus): void => {
        this.onHoldingHandChanged(data as number);
      };
      motion.on('holdingHandChanged', this.gripCallback);
      this.gripSubscribed = true;
    } catch (_e) {
    }
  }

  private onHoldingHandChanged(status: number): void {
    if (status === 1) {
      this.setGrip('left');
    } else if (status === 2) {
      this.setGrip('right');
    }
  }

  private setGrip(hand: string): void {
    if (this.gripHand === hand) {
      return;
    }
    animateTo({ curve: curves.springMotion(0.5, 0.8) }, () => {
      this.gripHand = hand;
    });
  }

  private stopGripDetection(): void {
    if (this.gripSubscribed && this.gripCallback) {
      try {
        motion.off('holdingHandChanged', this.gripCallback);
      } catch (_e) {
      }
      this.gripSubscribed = false;
      this.gripCallback = null;
    }
  }

  private triggerKnock(hand: string): void {
    if (this.isKnocking) {
      return;
    }
    this.isKnocking = true;
    if (this.knockLockTimerId !== -1) {
      clearTimeout(this.knockLockTimerId);
    }
    this.knockLockTimerId = setTimeout(() => {
      this.isKnocking = false;
      this.knockLockTimerId = -1;
    }, this.KNOCK_LOCK_DURATION);

    const target = this.isShrunk ? 0 : 1;
    // 仅「打开侧栏」时采用敲击侧；已展开再敲另一侧只收起，不改方向（避免左右瞬移）
    if (target === 1 && (hand === 'left' || hand === 'right')) {
      this.gripHand = hand;
    }
    if (target === 1) {
      this.vibrateHard();
      animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
        this.edgeHintOpacity = 0;
      });
    } else {
      this.vibrateLight();
      animateTo({ duration: 320, curve: Curve.EaseInOut }, () => {
        this.edgeHintOpacity = 0.55;
      });
    }
    this.animateShrink(target);
  }

  private vibrateHard(): void {
    vibrator.startVibration({ type: 'preset', effectId: 'haptic.effect.hard', count: 1 }, { usage: 'touch' })
      .catch((_err: BusinessError) => {
        vibrator.startVibration({ type: 'time', duration: 80 }, { usage: 'touch' }).catch(() => {});
      });
  }

  private vibrateLight(): void {
    vibrator.startVibration({ type: 'time', duration: 30 }, { usage: 'touch' }).catch(() => {});
  }

  private animateShrink(target: number): void {
    this.isShrunk = target >= 0.5;
    animateTo({ duration: 360, curve: Curve.FastOutSlowIn }, () => {
      this.shrinkProgress = target;
    });
  }

  private fgWidth(): number {
    return this.screenWidthVp * (1 - this.SHRINK_RATIO * this.shrinkProgress);
  }

  private fgOffsetX(): number {
    if (this.gripHand === 'right') {
      return 0;
    }
    return this.screenWidthVp * this.SHRINK_RATIO * this.shrinkProgress;
  }

  private subOffsetX(): number {
    if (this.gripHand === 'right') {
      return this.screenWidthVp * (1 - this.SHRINK_RATIO);
    }
    return 0;
  }

  private leftIsLight(): boolean {
    if (this.shrinkProgress < 0.5) {
      return true;
    }
    return this.gripHand === 'right';
  }

  private rightIsLight(): boolean {
    if (this.shrinkProgress < 0.5) {
      return true;
    }
    return this.gripHand === 'left';
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 底层始终挂载（与 SideTap 一致），避免缩窄时面板突然出现
      this.SubInterface()

      Stack({ alignContent: Alignment.TopStart }) {
        KyotoPost({
          viewHeight: this.screenHeightVp,
          topInset: this.STATUS_BAR_HEIGHT,
          onFollowTap: () => {
            this.debugVisible = !this.debugVisible;
          },
          onBackTap: () => {
            router.back();
          },
        })
        this.EdgeDrag()
        // 全屏时近手侧细条提示：告诉用户可侧敲 / 边缘双击
        if (!this.isShrunk) {
          this.EdgeHint()
        }
        if (this.flowReady && this.isShrunk) {
          Stack() {}
            .width('100%')
            .height('100%')
            .borderRadius(this.CORNER_RADIUS * this.shrinkProgress)
            .clip(true)
            .visualEffect(this.flowEffect!)
            .opacity(0.75)
            .hitTestBehavior(HitTestMode.None)
        }
      }
      .width(this.fgWidth())
      .height('100%')
      .backgroundColor(Color.White)
      .clip(true)
      .borderRadius(this.CORNER_RADIUS * this.shrinkProgress)
      .translate({ x: this.fgOffsetX() })
      .shadow({ radius: 24 * this.shrinkProgress, color: '#33000000', offsetX: 0, offsetY: 0 })

      this.StatusBarOverlay()

      if (this.toastVisible) {
        this.DetectionToast()
      }

      if (this.debugVisible) {
        this.DebugPanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0F172A')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  DetectionToast() {
    Column() {
      Text(this.toastText)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .padding({ left: 18, right: 18, top: 10, bottom: 10 })
        .borderRadius(20)
        .backgroundColor('#CC0F172A')
        .backdropBlur(16)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.None)
    .margin({ bottom: 80 })
  }

  @Builder
  EdgeHint() {
    Column() {
      Column() {
        Column()
          .width(3)
          .height(48)
          .borderRadius(2)
          .backgroundColor('#99FFFFFF')
      }
      .width(18)
      .height(72)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .borderRadius(12)
      .backgroundColor('#1A0F172A')
      .opacity(this.edgeHintOpacity)
      .margin({ bottom: 120 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(this.gripHand === 'right' ? HorizontalAlign.End : HorizontalAlign.Start)
    .padding({ left: 4, right: 4 })
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  StatusBarOverlay() {
    Row() {
      Text(this.clock)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.leftIsLight() ? '#1F2937' : '#FFFFFF')
      Blank()
      SymbolGlyph($r('sys.symbol.wifi_6'))
        .fontSize(17)
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        .fontColor([this.rightIsLight() ? '#1F2937' : '#FFFFFF'])
      SymbolGlyph($r('sys.symbol.battery_fill'))
        .fontSize(20)
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        .fontColor([this.rightIsLight() ? '#1F2937' : '#FFFFFF'])
        .margin({ left: 7 })
    }
    .width('100%')
    .height(this.STATUS_BAR_HEIGHT)
    .padding({ left: 24, right: this.CAMERA_INSET, top: 4 })
    .alignItems(VerticalAlign.Center)
    .translate({ y: -4 })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  EdgeDrag() {
    Column() {
      Column() {}
        .width(28)
        .height('100%')
        .backgroundColor(Color.Transparent)
        .gesture(
          TapGesture({ count: 2 })
            .onAction(() => this.triggerKnock(this.gripHand))
        )
        .gesture(
          PanGesture({ direction: PanDirection.Horizontal })
            .onActionStart(() => {
              // 仅已缩窄时可跟手拖回；展开阶段禁止拖（与 SideTap 一致）
              this.panEnabled = this.isShrunk;
              this.panStartProgress = this.shrinkProgress;
            })
            .onActionUpdate((e: GestureEvent) => {
              if (!this.panEnabled) {
                return;
              }
              const shrinkDist = this.SHRINK_RATIO * this.screenWidthVp;
              if (shrinkDist <= 0) {
                return;
              }
              const delta = (this.gripHand === 'right' ? -e.offsetX : e.offsetX) / shrinkDist;
              let p = this.panStartProgress + delta;
              p = Math.max(0, Math.min(1, p));
              this.shrinkProgress = p;
            })
            .onActionEnd(() => {
              if (!this.panEnabled) {
                return;
              }
              const target = this.shrinkProgress >= 0.5 ? 1 : 0;
              this.animateShrink(target);
              animateTo({ duration: 280, curve: Curve.EaseInOut }, () => {
                this.edgeHintOpacity = target < 0.5 ? 0.55 : 0;
              });
            })
        )
    }
    .width('100%')
    .height('100%')
    .alignItems(this.gripHand === 'right' ? HorizontalAlign.End : HorizontalAlign.Start)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  SubInterface() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Text('小艺')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .width('100%')

        Text('侧敲唤起 · 左/右识别')
          .fontSize(12)
          .fontColor('#94A3B8')
          .width('100%')
          .margin({ top: 4, bottom: 8 })

        Blank()

        this.ServiceCard($r('app.media.kyoto5'), '宇治抹茶体验',
          this.modelReady ? '模型就绪 · 实时监听' : '模型加载中…')
        this.ServiceCard($r('app.media.kyoto1'), '最近识别',
          this.lastDetectionLabel.length > 0
            ? `${this.lastDetectionLabel} · 共 ${this.detectionCount} 次`
            : '等待侧边双击')

        Flex({ wrap: FlexWrap.Wrap }) {
          this.SuggestChip('展开帖子', () => {
            if (this.isShrunk) {
              this.triggerKnock(this.gripHand);
            }
          })
          this.SuggestChip(this.gripHand === 'right' ? '切左手' : '切右手', () => {
            this.setGrip(this.gripHand === 'right' ? 'left' : 'right');
          })
          this.SuggestChip('调试', () => {
            this.debugVisible = !this.debugVisible;
          })
        }
        .width('100%')
        .margin({ top: 2, bottom: 12 })

        this.VoiceBar()
      }
      .width(this.screenWidthVp * this.SHRINK_RATIO)
      .height('100%')
      .translate({ x: this.subOffsetX() })
      .padding({ left: 12, right: 12, top: this.STATUS_BAR_HEIGHT + 8 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0F172A')
  }

  @Builder
  ServiceCard(img: Resource, title: string, subtitle: string) {
    Row() {
      Image(img)
        .width(56)
        .height(56)
        .objectFit(ImageFit.Cover)
        .borderRadius(12)
      Column() {
        Text(title)
          .fontSize(14)
          .fontColor('#F8FAFC')
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(subtitle)
          .fontSize(11)
          .fontColor('#94A3B8')
          .margin({ top: 3 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(15)
        .fontColor(['#64748B'])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
    }
    .width('100%')
    .padding(10)
    .borderRadius(16)
    .backgroundColor('#1FFFFFFF')
    .backdropBlur(12)
    .margin({ bottom: 10 })
  }

  @Builder
  SuggestChip(label: string, onTap: () => void) {
    Text(label)
      .fontSize(12)
      .fontColor('#E2E8F0')
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .borderRadius(15)
      .backgroundColor('#1AFFFFFF')
      .margin({ right: 8, bottom: 8 })
      .onClick(onTap)
  }

  @Builder
  VoiceBar() {
    Row() {
      SymbolGlyph($r('sys.symbol.waveform'))
        .fontSize(22)
        .fontColor(['#FFFFFF'])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      Text(this.isDetecting ? '正在监听侧边敲击…' : '等待传感器启动')
        .fontSize(13)
        .fontColor('#FFFFFF')
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .maxLines(1)
      Text(`${(this.probability * 100).toFixed(0)}%`)
        .fontSize(14)
        .fontColor('#22D3EE')
        .fontWeight(FontWeight.Medium)
    }
    .width('100%')
    .height(58)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .borderRadius(29)
    .backgroundColor('#26FFFFFF')
    .backdropBlur(18)
    .shadow({ radius: 18, color: '#4D000000', offsetX: 0, offsetY: 6 })
    .margin({ bottom: 16 })
  }

  @Builder
  DebugPanel() {
    Column() {
      Column({ space: 8 }) {
        Text('识别调试')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#E2E8F0')
          .width('100%')
        Text(getTapModelProfile(this.modelVariant).label)
          .fontSize(12)
          .fontColor('#22D3EE')
          .width('100%')
        Button(this.modelSwitching ? '切换中…' :
          (this.modelVariant === TapModelVariant.Features ? '切回原始 IMU 模型' : '切换特征 IMU 模型'))
          .fontSize(12)
          .enabled(!this.modelSwitching)
          .onClick(() => this.switchModel())
        Text(`模型 ${this.modelReady ? '✓' : '✗'}  ·  采集 ${this.isDetecting ? '✓' : '✗'}`)
          .fontSize(12)
          .fontColor('#94A3B8')
          .width('100%')
        Text(`150ms 峰值 ${(this.probability * 100).toFixed(0)}%  ·  触发 ${this.detectionCount} 次`)
          .fontSize(12)
          .fontColor('#94A3B8')
          .width('100%')
        Text(`握持 ${this.gripHand === 'right' ? '右手' : '左手'}${this.gripGranted ? '' : ' (手动)'}`)
          .fontSize(12)
          .fontColor('#94A3B8')
          .width('100%')
        Text(`最近 ${this.lastDetectionLabel.length > 0 ? this.lastDetectionLabel : '—'}`)
          .fontSize(12)
          .fontColor(this.lastDetectionLabel === '左敲' ? '#86EFAC' :
            (this.lastDetectionLabel === '右敲' ? '#FCA5A5' : '#94A3B8'))
          .width('100%')
        if (this.modelError !== '') {
          Text(this.modelError)
            .fontSize(12)
            .fontColor('#FCA5A5')
            .width('100%')
        }
      }
      .width(280)
      .padding(14)
      .borderRadius(12)
      .backgroundColor('#CC0B1220')
      .backdropBlur(12)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 12, bottom: 78 })
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
