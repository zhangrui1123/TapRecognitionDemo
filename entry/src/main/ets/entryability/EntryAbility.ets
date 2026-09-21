import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'TapRecognitionDemo', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'TapRecognitionDemo', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'TapRecognitionDemo', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'TapRecognitionDemo', '%{public}s', 'Ability onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'TapRecognitionDemo', 'Failed to load content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'TapRecognitionDemo', 'Succeeded in loading the content.');

      // 与 SideTap 一致：沉浸式全屏，隐藏系统状态栏（自定义状态栏由 Demo 页绘制），保留底部导航手势条
      try {
        const mainWin = windowStage.getMainWindowSync();
        mainWin.setWindowLayoutFullScreen(true);
        mainWin.setWindowSystemBarEnable(['navigation']);
      } catch (e) {
        hilog.error(DOMAIN, 'TapRecognitionDemo', 'Failed to set immersive mode. Cause: %{public}s', JSON.stringify(e));
      }
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'TapRecognitionDemo', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'TapRecognitionDemo', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'TapRecognitionDemo', '%{public}s', 'Ability onBackground');
  }
}
