# 许可边界

| 范围 | 许可 | 文件 |
|---|---|---|
| 仓内 metadata 与脚本(`setup.sh`、`ci/`、`.github/`、layer conf、image recipe) | MIT | 仓根 `LICENSE` |
| 内核相关产物(`meta-lubancat/recipes-kernel/` 下的 dts 与 patch) | GPL-2.0+ OR MIT | `LICENSES/GPL-2.0-only.txt` |

## 为什么内核那部分单列

`rk3566-lubancat-1io.dts` `#include` 了 Rockchip 的 `rk3566-evb2-lp4x-v10.dtsi`
与 `rk3568-linux.dtsi`,是它们的衍生作品,不能自行改许可。上游那两份的 SPDX 是
`(GPL-2.0+ OR MIT)`,所以本仓的 dts 也照抄这一条 —— **双许可,不是 GPL-2.0-only**。
早先这里写的是 GPL-2.0-only,那是在还没有真 dts、只按最保守情况估的;现在有了
实际文件,以文件头的 SPDX 为准。

本仓是**公开仓**,发布即构成再分发,所以许可声明必须随附。这不是形式主义:
P1–P3 阶段仓里只有自写的脚本和 conf,确实不需要;写自己的 dts 之前必须补齐。
