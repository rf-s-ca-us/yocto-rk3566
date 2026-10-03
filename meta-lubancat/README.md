# meta-lubancat

本仓唯一自写的 Yocto layer,面向野火 LubanCat1-BTB 核心板与官方 BTB IO
底板。当前同时承载 BSP、distro、镜像政策和 Hermes 应用供给,尚未拆层。
第三方 layer 留在 `layers/`,由仓根 `setup.sh` 获取。

## 依赖

`LAYERDEPENDS_lubancat` 声明以下五个 collection;第三方源码全部锁定在
已验证的 scarthgap commit SHA,具体版本以 `setup.sh` 为准。

| collection | 来源 |
|---|---|
| `core` | poky/meta |
| `openembedded-layer` | meta-openembedded/meta-oe |
| `rockchip` | JeffyCN/meta-rockchip |
| `virtualization-layer` | meta-virtualization |
| `rauc` | meta-rauc |

构建还需启用 meta-virtualization 的依赖闭包,包括 meta-python、
meta-networking 和 meta-filesystems。完整 `BBLAYERS` 见仓根
[README](../README.md);配置 `MACHINE = "rk3566-lubancat"` 和
`DISTRO = "lubancat"` 后构建 `lubancat-image-minimal`。

## 内容与边界

| 内容 | 责任 |
|---|---|
| machine、DTS、RTL8821CU、U-Boot 补丁、wks | 硬件支持、可烧录镜像与 A/B 引导 |
| distro、image、network/ssh/wifi、container.cfg | systemd、包集合、联网登录及容器能力 |
| RAUC 配置、OTA 客户端、ota.cfg | rootfs 升级、启动自检与回退所需配置 |
| Hermes/Python/Node/mihomo/ripgrep/VS Code Server | 原生应用与开发工具供给 |

`KERNEL_DEVICETREE = "rockchip/rk3566-lubancat-1io.dtb"`,已使用本板自写
DTS。EVB DTB 是早期构建验证时的过渡方案。内核跟随 meta-rockchip 的
vendor 6.1,本层不覆盖 `PREFERRED_VERSION_linux-rockchip`。

`BBFILE_PRIORITY_lubancat = "10"`,高于 rockchip 的 `9`。同名 recipe 的
选择与多个 bbappend 的解析顺序需区分;匹配的 bbappend 会共同生效。

Hermes 已原生进入 rootfs,Podman 保留。Hermes 和 mihomo 的服务随镜像
安装但默认不启用;凭据和代理配置由运行时提供,验通后人工 enable。
当前 `/root/.hermes` 与 `/etc/mihomo` 不属于共享 data 分区。

OTA 只更新非活动 rootfs 槽,共享 boot、U-Boot 和 data 不在升级载荷内。
2026-10-03 的构建与分发链已通过 CI;env 掉电持久化、实际安装切槽、
断电重试和失败回退仍需按 `docs/plans/2026-10-03-ota-board-acceptance.md`
上板验收。

## 补丁与贡献

本层补丁在 <https://github.com/rf-s-ca-us/yocto-rk3566> 提 PR。
vendor 内核补丁放在 `recipes-kernel/linux/files/`,由 bbappend 引入;
U-Boot 补丁放在 `recipes-bsp/u-boot/files/`。

## 维护

Maintainer: jx.song <jx.song.zuvi@gmail.com>
