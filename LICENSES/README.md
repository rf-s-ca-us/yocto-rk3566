# 许可边界

| 范围 | 许可 | 文件 |
|---|---|---|
| 仓内 metadata 与脚本(`setup.sh`、`ci/`、`.github/`、layer conf、image recipe) | MIT | 仓根 `LICENSE` |
| 内核相关产物(`meta-lubancat/recipes-kernel/` 下的 dts 与 patch) | GPL-2.0-only | `LICENSES/GPL-2.0-only.txt` |

## 为什么内核那部分必须是 GPL-2.0

`rk3566-lubancat.dts` 从 `meta-rockchip` 的 EVB dts 改写而来、并 `#include` 了
vendor 的 `rk3566.dtsi`,属于 GPL-2.0 源码的衍生作品。本仓是**公开仓**,发布
即构成再分发,因此必须随附许可声明。

这不是形式主义:P1–P3 阶段仓里只有自写的脚本和 conf,确实不需要;**但写自己的
dts 之前必须补齐**,所以它是 P4 的前置门(验收用例 B4)。
