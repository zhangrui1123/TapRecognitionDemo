/**
 * 沉浸光感「流光」特效构建（HarmonyOS hdsEffect，API 20+）。
 * 集中放这里，方便统一调色 / 调速度，UI 侧只管 .visualEffect(...) 应用。
 *
 * 注意：DUAL_EDGE_FLOW_LIGHT 只有 first/second 两个颜色；
 *       startPos→endPos 越过 1.0 形成 wrap = 整圈环绕；Curve.Linear 匀速 = 无缝循环不跳变。
 */
import { hdsEffect } from '@kit.UIDesignKit';

export class FlowEffects {
  // 前台 App 边缘流光：整圈环绕、青→粉、5s 匀速循环。需要外部传入 controller。
  static edgeFlow(controller: hdsEffect.ShaderEffectController): VisualEffect {
    return new hdsEffect.HdsEffectBuilder()
      .shaderEffect({
        effectType: hdsEffect.EffectType.DUAL_EDGE_FLOW_LIGHT,
        animation: { duration: 5000, iterations: -1, autoPlay: true, curve: Curve.Linear },
        controller: controller,
        params: {
          firstEdgeFlowLight: { startPos: 0, endPos: 1.0, color: '#1AD0F1' },
          secondEdgeFlowLight: { startPos: 0.5, endPos: 1.5, color: '#FFA4E5' }
        } as hdsEffect.DualEdgeFlowLightParam
      })
      .buildEffect();
  }
}
