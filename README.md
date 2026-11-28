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

OTA 当前只替换 rootfs。内核、DTB 与 U-Boot 更新需整盘重烧。
共享 data 挂在 `/var/lib/containers`(容器存储和 OTA 败记档)。Wi-Fi 凭据、
`/root/.hermes`、`/root/.local/state/hermes` 与 `/etc/mihomo` 也放在这块盘上,
开机 bind 回原来的路径,换槽还在。这些文件不进镜像、不进 CI。从旧槽升级时,
bundle 在写盘前先把目标槽上已有的配置抢救出来;正在运行的槽是空的也不用空目录
盖掉它。新槽首启再收入 data,空目录不会被 bind。

#88 的 U-Boot 里 `ab_boot` 用了 `break`,而这版 vendor U-Boot 没有这条命令。
`BOOT_ORDER=A B` 时循环会把 `BOOT_SLOT` 留在最后一个有剩余次数的槽,所以默认
环境实际启动 B。这个选槽修在 U-Boot 里,rootfs OTA 带不走,要整盘重烧新的
bootloader。`env default -a; saveenv; reset` 只清旧环境,清不掉这个脚本问题。
镜像仍不会自动清环境:自动清会把已经配对的环境一起抹掉。

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

已经烧录的板子上,`rootfs_a` / `rootfs_b`(`mmcblk0p3` 与 `p4`)各是
**13459188 个 512 字节扇区 = 6,891,104,256 字节**。这个数写在
`lubancat-ab.wks.in` 的 `--fixed-size 6729594k`(6729594 KiB,wic 的 `k`
是 KiB),是分区表的真源。在线升级不改分区表,所以每一份打进 bundle 的
`rootfs.ext4` 都必须 ≤ 这个槽。

镜像不再在内容之上追加 4 GiB。那样做时 ext4 会跟着内容涨,发布版
`93-c5411847` 就比槽多了 16384 字节,`rauc install` 报 slot too small。
生成尺寸钉在槽位减去 **16 MiB**:`IMAGE_ROOTFS_SIZE` 是下限,
`core-image-minimal` 为 systemd 追加的 4096 KiB 加在下限之后,所以下限先
扣掉这 4096,最终文件是槽位减 16 MiB。`IMAGE_ROOTFS_MAXSIZE` 等于槽位,
算出来更大则构建失败。CI 再对最终 `rootfs.ext4` 的字节数做一次比较。

这 16 MiB 是余量。槽里大约 4 GiB 的空闲还在(内容约 1.9 GiB,文件系统约
6.40 GiB,`df` 还要再扣 ext4 元数据和保留块),小包先占用这份空闲,镜像
文件不会跟着涨。内容本身(含 1.3 倍余量)超过下限之后,镜像才开始向槽位
涨,涨过槽位就被 `IMAGE_ROOTFS_MAXSIZE` 和 CI 拦住。

`--fixed-size` 与 wic 的 `--overhead-factor` / `--extra-space` 互斥。
`--align 8192` 只对齐分区起点。两槽容量相同,引导相关分区与 PARTUUID 不变。
新烧的卡和已经在跑的板子是同一个槽位大小。OTA 用的是 deploy 里那份较小的
`rootfs.ext4`;wic 在分区里另外做一份刚好填满槽的文件系统,不拿那份去打 bundle。

Rockchip `parameter` 保留最后的 `data:grow`,烧录时 data 分区使用剩余空间;
直接写入 WIC 时,data 仍按布局中的 2 GiB 创建。烧录包不携带 grow 分区里的
文件系统。首启只格式化分区名是 data、内容探测没有识别出文件系统或加密卷、
且将写入的范围全为零的分区,做成 `LABEL=data` 的 ext4,文件系统大小等于
当时的分区。空分区上 `blkid -p` 也会因分区表项退出 0,不能拿这个退出码判断
已经格式化。已经有文件系统或其它内容的分区不会被格式化。data 没有挂上时,
该目录会被改成只读,容器数据不会写进当前槽的 rootfs。WIC 里预先做好的 ext4
因此保持 2 GiB,不会在首启被扩成整盘。

p3/p4/p5 的尺寸保持不动,已经烧过的板子不用重分区就能装新的 rootfs。
data 分区的首启规则不变。重新烧录前仍要备份需要保留的数据。

## 宿主机要求

- **不能用 root 跑 bitbake**——OE 的 sanity checker 会直接拒绝
- locale 需要 `en_US.UTF-8`(只有 `C.utf8` 不行:`localedef -i en_US -f UTF-8 en_US.UTF-8`)
- host 工具:`chrpath cpio diffstat gawk lz4 zstd`

## 仓里只放自己写的东西

第三方源码、blob、模型一律由 `setup.sh` 或 recipe 按官方渠道拉取,不入库。
`.gitignore` 是白名单式的——默认忽略一切、逐条放行,好让"忘了加规则"的失败
模式是漏提交而不是误提交。
