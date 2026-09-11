# 背景图片预览工具

用 Edge、Chrome 或 Firefox 打开 `background-preview.html` 即可。单个 HTML 可独立复制给其他人，
不依赖服务器、Node.js、第三方库或 Weasel 安装，图片不会上传。

1. 打开图片或拖入原图区；建议使用 PNG。
2. 在原图拖动四条切线，或填写 left/top/right/bottom。切线挤在一起时，先选择“拖动哪条线”。
3. 调整 scale、padding_left 和圆角；切换背景区域宽高及 DPI，观察人物是否变形或被文字覆盖。
4. 复制或下载 YAML，将对应内容合并到 `weasel.custom.yaml` 的现有 `patch:` 下。
5. 将原图放入 Rime 用户目录的对应路径，然后重新部署。工具不会自动改动输入法配置。

也可以粘贴已有 `style/background` 配置块导入。图片需要另行打开；导入器只读取支持的背景字段
和 `style/layout/corner_radius`，不是通用 YAML 编辑器。新图无法容纳当前切片时，会改为三等分。

预览窗口宽高是最终背景区域大小，不能直接当作 min_width/min_height：实际窗口还受文字、边距
和留白影响，因此导出不包含这两个布局参数。底色、示意文字和网格用于观察，不写入 YAML。
PNG 导出包含当前底色、示意文字（可关闭）及透明圆角，不包含调试网格。

切片边界、基础缩放、DPI 和小窗口收缩对应 `WeaselUI/NineSlice.h`。
scale 范围 1–400、padding_left 范围 0–2000 与配置读取器一致。
浏览器图像插值、透明边缘处理及文字排版不是 GDI+/DirectWrite 的像素级复现。
全屏和竖排文字布局不在本工具的模拟范围内。

开发测试（可选，需要 Node.js 18+）：

```text
node --test tools/background-preview.test.cjs
```

测试以轻量 DOM/canvas 记录器运行实际内嵌脚本，覆盖源/目标切片边界、DPI、小窗口、
零边距、参数校验、拖动边界、YAML 往返及导入字段隔离。它不代替浏览器视觉验收。
