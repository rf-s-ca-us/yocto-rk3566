# vision-station — RK3566 NPU 视觉小站

给 LubanCat1-BTB 加一只"会看东西的眼睛":USB UVC 摄像头采集,板载
NPU(RK3566,1 TOPS)跑 YOLOv8n 做人形/宠物侦测,局域网网页看带框
实时画面,侦测事件抓拍落盘,并经板上 Hermes 通道推送到手机。

设计稿(已于 2026-11-24 审计通过)在文档仓 yocto-rk3566-docs:
`plans/2026-11-24-npu-vision-station-design.html`。

## 目录

| 路径 | 是什么 |
|---|---|
| `app/` | 主程序:帧源(camera/dir/synthetic)× 检测后端(rknn/fake/none),事件引擎(目标类别+冷却+快照+通知钩子),MJPEG 预览服务 |
| `model/` | 模型流水线:`fetch-model.sh` 拉官方 ONNX 并校验 SHA-256,`convert.py` 用 RKNN-Toolkit2 转 RKNN。模型不进仓 |
| `container/` | 板上运行镜像的 Containerfile(RKNN 运行时构建期按官方渠道拉取,钉版本) |
| `tests/` | host 测试:后处理解码/NMS、事件引擎、预览服务冒烟 |
| `config.example.json` | 配置样例(板上放 `/etc/vision-station/config.json`) |

## host 验证(无硬件)

```sh
python3 tests/test_postprocess.py   # 需要 numpy
python3 tests/test_events.py
python3 tests/smoke_server.py
# 端到端冒烟(合成帧 + 假检测器):
python3 app/vision_station.py --source synthetic --detector fake \
    --bind 127.0.0.1 --port 8090 --snapshot-dir /tmp/vs-snaps
# 浏览器打开 http://127.0.0.1:8090/ 看预览,/health 看状态
```

## 模型

```sh
cd model && ./fetch-model.sh        # 产物落 ../models/,已 gitignore
```

ONNX 来源是 Rockchip `rknn_model_zoo` 官方 `download_model.sh` 指向
的文件托管,SHA-256 在脚本里钉死(2026-11-24 实测)。转换在 x86
host 上用 RKNN-Toolkit2 做,默认 FP 不量化——INT8 量化要校准集,
等实机测过基线帧率再评估。

## 板上运行(阶段 1,待阶段 0 自检后)

先决条件(设计稿阶段 0):板上确认 NPU 驱动与设备节点存在
(`dmesg | grep -i rknpu; ls /dev/dri/; ls /dev/video*`)、摄像头
插上能枚举。构建与运行命令见 `container/Containerfile` 头注释。

## 当前状态

- 阶段 0(上板验 NPU 前提):待用户执行自检。
- 阶段 1(容器原型):代码与 host 验证已就绪,待阶段 0 结论上板。
- 阶段 2(layer 固化):未开始;若自检发现驱动缺席,先加 `npu.cfg`
  内核片段 + CI 断言,再谈固化。
- 阶段 3(事件推送接 Hermes):通知钩子接口已留(`notify_cmd` +
  `VS_EVENT_*` 环境变量),板上接线时配置。
