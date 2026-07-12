# 敲一敲识别 Demo

HarmonyOS 手机端双击（敲一敲）手势识别演示应用。

当用户在手机上双击背面或边框时，界面会显示 **敲一敲**。

## 架构

```
IMU 传感器 (100Hz)
    ↓
ImuStreamCollector   ← 来自 IMUCollector 的对齐/重采样逻辑
    ↓
TapPreprocessor      ← 高通滤波 + EMA 归一化（与 PC 端 inference.py 一致）
    ↓
TapDetector          ← MindSpore Lite 加载 tap_recognition.ms
    ↓
UI 显示「敲一敲」
```

## 依赖项目

| 项目 | 路径 | 用途 |
|------|------|------|
| TapRecognition | `D:\Projects\TapRecognition` | 训练模型、推理逻辑、`.ms` 模型文件 |
| IMUCollector | `D:\Projects\IMUCollector` | IMU 采集与 100Hz 重采样（`ImuAligner`） |

模型文件：`entry/src/main/resources/rawfile/tap_step.ms`（单步流式推理模型，从 TapRecognition 导出）

> 旧版 `tap_recognition.ms` 使用 64 帧滑窗批量推理，无法保持 GRU 状态且推理慢时会丢帧，已弃用。

## 使用方式

1. 在 DevEco Studio 中打开本项目
2. 连接 HarmonyOS 手机，编译并安装
3. 点击 **开始监听**
4. 双击手机背面或边框，界面显示 **敲一敲**

## 重新导出模型

若 TapRecognition 模型有更新：

```bash
# 1. 导出单步流式 ONNX（与 PC 端 model.step() 一致）
python tools/export_step_for_harmony.py --checkpoint checkpoints/best.pt

# 2. 转换为 .ms
converter_lite --fmk=ONNX --modelFile=checkpoints/tap_step.onnx --outputFile=checkpoints/tap_step --inputShape="x_t:1,6;cnn_buffer:1,32,29;h_in:1,1,64"

# 3. 复制到本项目
copy checkpoints\tap_step.ms entry\src\main\resources\rawfile\
```

## 核心文件

- `entry/src/main/ets/pages/Index.ets` — 演示界面
- `entry/src/main/ets/model/ImuStreamCollector.ets` — 实时 IMU 流
- `entry/src/main/ets/model/TapDetector.ets` — MindSpore Lite 推理 + 迟滞检测
- `entry/src/main/ets/model/TapPreprocessor.ets` — 预处理（与 PC 端一致）

## 检测参数

与训练配置 `config/train.yaml` 及 PC 端 `inference.py` 保持一致：

- 预处理：2 阶 Butterworth 高通（0.5Hz @ 100Hz），**无** EMA 归一化
- 触发阈值：0.5（`prediction_threshold`），释放阈值：0.3
- 连续触发帧数：2
- 不应期：0.5 秒

### 真机召回率低的原因（已修复）

| 问题 | 离线 | 旧版真机 |
|------|------|----------|
| 高通滤波 | scipy Butterworth 2 阶 | 一阶 RC 近似 |
| EMA 归一化 | 无 | 有（训练未使用） |
| 触发阈值 | 0.5 | 0.7 |
