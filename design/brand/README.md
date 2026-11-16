# 战术之眼

“战局助手 / TACTIC”的原创单色图标，与应用的墨黑、暖白和灰色界面保持一致。

- 开口雷达圆环：观察小地图和战场变化。
- 右上箭头：指出当下最关键的方向和行动。
- 对话尾巴：把局势转成一句能听见的提醒。

母版为 `tactic-icon.svg`，512×512，背景 `#171918`、主图形 `#F4F4EE`。桌面资源保留实色方形背景，由系统统一裁切图标外轮廓；启动页使用透明背景的深色标记。主标记留有安全边距，并在32、48、64、88像素展示中检查了轮廓。

资源对应：

| 用途 | 文件 |
| --- | --- |
| 应用图标 | `AppScope/resources/base/media/app_icon.png` |
| 桌面入口图标 | `entry/src/main/resources/base/media/icon.png` |
| 启动页图标 | `entry/src/main/resources/base/media/startIcon.png` |
| 设计展示 | `artifacts/brand-preview.png` |

以上路径相对项目根目录。入口Ability引用独立的 `icon` 资源，必须和应用图标一起更新，才能替换桌面上的默认四方块。

在安装了Pillow和Chrome的Windows环境中，从项目根目录运行：

```powershell
& 'D:\Anaconda3-5.3.1\anaconda3\python.exe' tools/render-brand-assets.py
```

其他Chrome安装位置可通过 `--browser` 指定。脚本从SVG母版生成三个512×512 PNG，再用 `preview.html` 生成1120×840展示图；浏览器缓存只写入项目的 `tools/.cache/brand-render`。本次随应用1.0.10版发布，安装后的系统圆角及图标掩膜以设备桌面为准。
