# yocto-rk3566

用 Yocto **scarthgap**(5.0 LTS)把 RK3566 板子 `rk3566-lubancat` 从零跑起来。

内核走 Rockchip vendor 6.1(`meta-rockchip` 在 scarthgap 上的默认值),NPU 因此
可用;代价是 DTS bindings 是 Rockchip 私有、无上游路径。取舍见设计稿。

## 目录

| 路径 | 是什么 |
|---|---|
| `setup.sh` | 拉第三方 layer 到 `layers/`(不进 git) |
| `meta-lubancat/` | 本仓唯一自写的 Yocto layer |
| `ci/` | sstate seed 脚本与 mirror 配置说明 |

## 快速开始

```sh
./setup.sh                                  # 拉 poky / meta-openembedded / meta-rockchip / meta-virtualization
ROOT=$PWD                                   # oe-init-build-env 会切目录,先存下来
. layers/poky/oe-init-build-env build
```

`conf/bblayers.conf` 的 `BBLAYERS`(下面这份是实测通过的):

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
  $ROOT/meta-lubancat \
"
```

`conf/local.conf` 追加:

```
MACHINE = "rk3566-lubancat"
DISTRO  = "lubancat"
INHERIT += "rm_work"
```

`DISTRO` 不能省。镜像里有 podman 靠的是 `DISTRO_FEATURES` 里的
`virtualization`,而那是配置级变量、recipe 改不动——它定义在
`meta-lubancat/conf/distro/lubancat.conf`,只有设了 `DISTRO` 才会被读进来。
用默认的 `poky` 编,能编过,但编出来的镜像里没有容器运行时。

然后 `bitbake lubancat-image-minimal`。

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
