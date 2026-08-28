# yocto-rk3566

用 Yocto **scarthgap**(5.0 LTS)把 RK3566 板子 `rk3566-lubancat` 从零跑起来。

内核走 Rockchip vendor 5.10(`meta-rockchip` 现成 recipe),NPU 因此可用;
代价是 DTS bindings 是 Rockchip 私有、无上游路径。取舍见设计稿。

## 目录

| 路径 | 是什么 |
|---|---|
| `setup.sh` | 拉第三方 layer 到 `layers/`(不进 git) |
| `meta-lubancat/` | 本仓唯一自写的 Yocto layer |
| `ci/` | sstate seed 脚本与 mirror 配置说明 |

## 快速开始

```sh
./setup.sh                                  # 拉 poky / meta-openembedded / meta-rockchip
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
  $ROOT/layers/meta-rockchip \
  $ROOT/meta-lubancat \
"
```

`conf/local.conf` 追加:

```
MACHINE = "rk3566-lubancat"
INHERIT += "rm_work"
```

然后 `bitbake lubancat-image-minimal`。

## 宿主机要求

- **不能用 root 跑 bitbake**——OE 的 sanity checker 会直接拒绝
- locale 需要 `en_US.UTF-8`(只有 `C.utf8` 不行:`localedef -i en_US -f UTF-8 en_US.UTF-8`)
- host 工具:`chrpath cpio diffstat gawk lz4 zstd`

## 仓里只放自己写的东西

第三方源码、blob、模型一律由 `setup.sh` 或 recipe 按官方渠道拉取,不入库。
`.gitignore` 是白名单式的——默认忽略一切、逐条放行,好让"忘了加规则"的失败
模式是漏提交而不是误提交。
