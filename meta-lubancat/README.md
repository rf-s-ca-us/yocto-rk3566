# meta-lubancat

RK3566 自制板 `rk3566-lubancat` 的 BSP layer。板级差异全在这里,其余一切
继承自 `meta-rockchip` 与 poky。

## 依赖

| layer | 来源 |
|---|---|
| `core` | poky/meta |
| `openembedded-layer` | meta-openembedded/meta-oe |
| `rockchip` | JeffyCN/meta-rockchip |

三者都由仓根的 `setup.sh` 拉到 `layers/`,固定在 `scarthgap` 分支。

## 加进构建

```
bitbake-layers add-layer /path/to/meta-lubancat
```

`conf/local.conf` 里设 `MACHINE = "rk3566-lubancat"`。

## 内容

| 路径 | 说明 |
|---|---|
| `conf/machine/rk3566-lubancat.conf` | machine 定义,`require` 了 `rk356x.inc` |
| `recipes-kernel/linux/linux-rockchip_%.bbappend` | 板级内核定制的挂载点 |
| `recipes-core/images/lubancat-image-minimal.bb` | 最小可启动镜像 |

内核跟随 `meta-rockchip` 默认的 Rockchip vendor 6.1,本 layer 不覆盖
`PREFERRED_VERSION`。

`BBFILE_PRIORITY_lubancat = "10"`,高于 `rockchip` 的 `9`,好让本 layer 的
bbappend 最后生效。

## 当前状态

`KERNEL_DEVICETREE` 暂时指向 Rockchip 公版 EVB 的 dtb。这是故意的——先证明
工具链、layer 结构、machine conf、镜像通路整条链是通的,再换成照原理图写的
自有 dts,这样"仓建错了"和"引脚填错了"不会混在一起。

## 维护

Maintainer: jx.song <jx.song.zuvi@gmail.com>
