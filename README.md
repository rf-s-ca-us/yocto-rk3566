# yocto-rk3566

用 Yocto **scarthgap**(5.0 LTS)把 RK3566 板子 `rk3566-lubancat` 从零跑起来。

内核走 Rockchip vendor 6.1,设备树使用自写的
`rockchip/rk3566-lubancat-1io.dtb`。镜像包含 Hermes 原生运行环境、Podman
和 RAUC A/B OTA;第三方 layer 由 `setup.sh` 按已验证的 commit SHA 拉取。

## 当前进度

2026-10-03 核对:基础镜像与 Hermes 有 2026-09-19 的实机通过记录;
OTA 阶段 2/3 的代码、CI 打包和 R2 stable 分发链已完成,实际升级、断电重试
与失败回退仍待上板。最新证据、待验项和操作入口见私有文档挂载点
`docs/HANDOFF.md`;拉取代码后用 `git submodule update --init docs` 同步文档。

OTA 当前只替换 rootfs。内核、DTB 与 U-Boot 更新需整盘重烧;
共享 data 挂在 `/var/lib/containers`,Hermes 的 `/root/.hermes` 与
`/etc/mihomo/config.yaml` 尚未迁到共享存储,换槽不会自动带走这些运行时配置。

## 目录

| 路径 | 是什么 |
|---|---|
| `setup.sh` | 拉第三方 layer 到 `layers/`(不进 git) |
| `meta-lubancat/` | 本仓唯一自写的 Yocto layer |
| `ci/` | 实机验收脚本、R2 mirror 与 OTA 渠道约定 |
| `docs/` | 私有文档 submodule:交接、操作手册、历史设计和 wiki |

## 快速开始

```sh
./setup.sh                                  # 按固定 SHA 拉五个第三方 layer,包含 meta-rauc
ROOT=$PWD                                   # oe-init-build-env 会切目录,先存下来
. layers/poky/oe-init-build-env build
```

`conf/bblayers.conf` 的 `BBLAYERS`(与 CI 的 layer 清单一致):

```
BBLAYERS ?= " \
  $ROOT/layers/poky/meta \
  $ROOT/layers/poky/meta-poky \
  $ROOT/layers/meta-openembedded/meta-oe \
  $ROOT/layers/meta-openembedded/meta-python \
  $ROOT/layers/meta-openembedded/meta-networking \
  $ROOT/layers/meta-openembedded/meta-filesystems \
  $ROOT/layers/meta-rockchip \
  $ROOT/layers/meta-virtualization \
  $ROOT/layers/meta-rauc \
  $ROOT/meta-lubancat \
"
```

`conf/local.conf` 追加:

```
MACHINE = "rk3566-lubancat"
DISTRO  = "lubancat"
INHERIT += "rm_work"
```

`DISTRO` 不能省。`lubancat.conf` 选择 systemd,启用 `virtualization` 与
`rauc`,并接受镜像所需 ffmpeg 的 `commercial` 许可旗标。只设置 MACHINE
不足以得到同一套镜像。`meta-rauc` 也不能漏:它是 `meta-lubancat` 声明的
layer 依赖,提供 `rauc` 和 CI 打包所用的 `rauc-native`。

然后 `bitbake lubancat-image-minimal`。

CI 为 OTA 设置 `OTA_VERSION = "<run_number>-<sha8>"`;本地不设置时
`/etc/ota-version` 默认为 `0`,不应把本地镜像误认成某个 CI 发布版本。

## rootfs 容量与 A/B 分区

每份 rootfs 的容量按 **Yocto 原有计算结果 + 4 GiB** 生成,随系统内容增长,
不固定为 4 GiB。image recipe 的 `IMAGE_ROOTFS_EXTRA_SPACE` 以 KiB 为单位,
追加 `4194304`,保留上游的容量余量、最小容量和 systemd 额外空间。
最终容量仍遵循上游对齐规则;4 GiB 是新增的文件系统容量,`df` 显示的可用
空间还会扣除 ext4 元数据和保留块。

`lubancat-ab.wks.in` 的 `rootfs_a`、`rootfs_b` 都使用该容量,并设置
`--overhead-factor 1 --extra-space 0`,避免 WIC 再次放大。
独立 ext4 产物也已经扩容,因此 WIC 与 Rockchip `update.img` 两条烧录路径
都能获得新增的文件系统容量。A/B 两槽容量相同,引导相关分区与 PARTUUID 不变。

例如原 rootfs 容量为 2.40 GiB,调整后每槽约 6.40 GiB,两槽合计约 12.80 GiB。
Rockchip `parameter` 保留最后的 `data:grow`,烧录时 data 分区使用剩余空间;
直接写入 WIC 时,data 仍按布局中的 2 GiB 创建。data 文件系统的初始化/扩容
仍按原流程处理,分区占满剩余空间不等于文件系统自动扩容。

这是新镜像的分区布局,不会在线调整已经运行的板子。重新烧录前备份需要保留的
数据,并确认 eMMC 能容纳两份 rootfs、启动内容及所需的数据空间。

## 宿主机要求

- **不能用 root 跑 bitbake**——OE 的 sanity checker 会直接拒绝
- locale 需要 `en_US.UTF-8`(只有 `C.utf8` 不行:`localedef -i en_US -f UTF-8 en_US.UTF-8`)
- host 工具:`chrpath cpio diffstat gawk lz4 zstd`

## 仓里只放自己写的东西

第三方源码、blob、模型一律由 `setup.sh` 或 recipe 按官方渠道拉取,不入库。
`.gitignore` 是白名单式的——默认忽略一切、逐条放行,好让"忘了加规则"的失败
模式是漏提交而不是误提交。
