# 项目结构

以下路径相对项目根目录，语音模型表中的文件相对模型目录。

## 页面与主要流程

| 文件或模块 | 用途 |
| --- | --- |
| `entry/src/main/ets/pages/CloudBattle.ets` | 首页、配置页、任务启停和设置保存。 |
| `entry/src/main/ets/entryability/EntryAbility.ets` | 打开首页并在应用退出时停止采集。 |
| `entry/src/main/resources/base/profile/main_pages.json` | 注册当前启用的页面。 |
| `entry/src/main/module.json5` | 声明应用入口、权限和后台任务类型。 |
| `AppScope/app.json5` | 设置包名、版本号和应用信息。 |
| `entry/src/main/ets/demo/GamePrompt.ets` | 定义战况分析要求、敌我识别规则和回复格式。 |
| `entry/src/main/ets/demo/CloudBattleApi.ets` | 请求云端模型并读取、检查回复。 |
| `entry/src/main/ets/demo/CloudImages.ets` | 导入截图、裁剪小地图并生成上传图片。 |
| `entry/src/main/ets/demo/MinimapCrop.ets` | 设置默认小地图范围并处理图片边缘。 |
| `entry/src/main/ets/demo/CloudImageQuality.ets` | 检查原始帧和小地图是否发黑。 |
| `entry/src/main/ets/demo/CloudPhoneScreen.ets` | 调用手机录屏并随屏幕旋转调整采集尺寸。 |
| `entry/src/main/ets/demo/CloudTiming.ets` | 控制请求间隔并跳过过时的画面和回复。 |
| `entry/src/main/ets/demo/BattleBriefing.ets` | 整理播报短句、重复提醒和语音停顿。 |
| `entry/src/main/ets/demo/LocalNeuralSpeech.ets` | 调用手机语音模型把文字合成为音频。 |
| `entry/src/main/ets/demo/VoicePlayer.ets` | 播放合成音频并控制停止。 |

## 语音模型

模型目录：`entry/src/main/resources/rawfile/local-tts/`。
资源清单：`entry/src/main/resources/rawfile/local-tts.json`，记录模型文件和校验值。

| 文件 | 用途 |
| --- | --- |
| `model.onnx` | Matcha 中文语音模型，根据文本生成声学特征。 |
| `vocoder.onnx` | Vocos 模型，把声学特征转换为音频波形。 |
| `tokens.txt` | 记录模型使用的发音符号。 |
| `lexicon.txt` | 记录词语和读音的对应关系。 |
| `phone.fst` | 处理电话号码的读法。 |
| `date.fst` | 处理日期的读法。 |
| `number.fst` | 处理数字的读法。 |

## 原生代码、资源与构建

| 文件或模块 | 用途 |
| --- | --- |
| `native/phone_capture/` | 手机录屏的 C++ 调用接口。 |
| `native/screen_capture.cpp` | 读取系统录屏画面并处理旋转。 |
| `native/phone_tts/` | 手机语音合成的 C++ 实现。 |
| `entry/libs/arm64-v8a/` | 随应用打包的六个手机原生库。 |
| `AppScope/resources/base/media/app_icon.png` | 手机桌面上的应用图标。 |
| `design/brand/` | 图标设计源文件和预览页面。 |
| `entry/src/main/ets/pages/` | 另保留 Index、Capture、Models 三个旧页面，入口关闭。 |
| `entry/src/main/ets/demo/LocalRuntime.ets` | 保留的手机本机推理实现，当前入口关闭。 |
| `backend/` | 保留的后端示例与模拟服务。 |
| `build-profile.json5` | 配置 SDK 版本、构建产品和签名。 |
| `oh-package.json5`、`oh-package-lock.json5` | 声明依赖并固定版本。 |
| `hvigor/`、`hvigorfile.ts` | 配置构建工具及工程构建任务。 |
| `tools/` | 构建、测试、模型准备和源码导出脚本。 |
| `tools/capture-api-evidence.json` | 记录旧版录屏接口的来源、版本和校验值。 |
| `tests/` | 自动测试脚本和采集模拟程序。 |
| `licenses/` | 第三方许可证和模型使用条款。 |
| `.gitignore` | 排除签名、密钥、构建产物和本机缓存。 |
| `README.md` | 工程简介、构建命令和源码分发说明。 |
