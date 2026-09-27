# OTA stable 渠道约定(单渠道单板,一页写完)

分发链:`.github/workflows/build.yml` 每轮把 rootfs 打成 rauc bundle 推 R2;
板上 systemd timer(lubancat-ota.timer,5min 起拍/15min 周期)拉 manifest 比版本,
更新才 `rauc install <url>` 流式写非活动槽。spec:`docs/plans/ota.md` 阶段 3。

## URL 布局

    <bucket>/
    └── ota/
        └── stable/                        ← 唯一渠道,无灰度无多环境
            ├── <version>/update.raucb     ← 版本目录,只增不改
            └── latest.json                ← 版本指针,CI 每轮最后原子写

- `<version>` = `<run_number>-<sha8>`(build.yml「生成构建配置」步算一次,三处同源:
  版本目录名、bundle 的 manifest version、镜像里的 `/etc/ota-version`)。
- 公开读基址即 `vars.SSTATE_BASE_URL`(现 `https://pub-b68514853b324ecaa66d426bae01a369.r2.dev`,
  非凭据)。r2.dev 域名官方限流,仅开发期;生产换 Cloudflare 自定义域(spec 既定)。

## latest.json

    {"version":"1234-a93658f2","url":"<基址>/ota/stable/1234-a93658f2/update.raucb","sha256":"<bundle 哈希>"}

| 字段 | 约定 |
|---|---|
| `version` | = 版本目录名 = manifest version = `/etc/ota-version`;比对只取 run_number 整数前缀 |
| `url` | bundle 直链,板上 `rauc install` 流式拉取 |
| `sha256` | bundle 内容哈希;CI 断言与实际产物一致后才发布 |

## 发布次序(原子性)

bundle 先传 → latest.json 后传(S3 单对象 PUT 原子)。读侧要么看到旧指针、
要么看到新指针;见到新指针时 bundle 必已在位。自查红的轮(镜像内容/内核
配置/dtb 任一硬门)不发渠道 —— 板上会自动装 latest.json 指的东西,红轮
发布等于喂未验产物。

## 保留策略

最近 **3** 个版本目录(run_number 数值序,含本轮);更旧的 `aws s3 rm --recursive`
清掉。latest.json 在 `ota/stable/` 顶层,不属于任何版本目录,不受清理影响。

## 版本比对与回滚

- 板上只比 run_number 整数前缀:远端 > 本地才装;等于幂等跳过;小于跳过 + 日志
  (防 R2 被回写旧版造成循环降级)。
- 回滚 = u-boot 两级安全网自动完成(BOOT_ORDER/BOOT_<x>_LEFT + bootcount/altbootcmd,
  见 `docs/plans/2026-09-26-ota-phase23.md` 开放项 1/3)。渠道侧无回滚动作,
  不防回滚(拍板)。

## bundle 格式与前置(2026-09-27 查证,钉定源码)

- 格式钉 **verity**:`rauc install <https URL>` 是流式路径,RAUC v1.15.2 明确拒绝
  plain 的流式安装("Bundle format 'plain' not supported in streaming mode",
  src/bundle.c check_bundle)⇒ 无得选。打包证书是当轮一次性自签(main.c
  bundle_start 形式要求 cert+key),板上无 keyring 不验签 —— 信任根是 R2
  写权限(拍板 3)。
- verity 安装需要内核 DM_VERITY 链路(RAUC src/dm.c 走 /dev/mapper/control 直调;
  hash 默认 sha256,Kconfig 不随 DM_VERITY 自动选)。vendor defconfig @ ea9e2a93
  缺 MD/BLK_DEV_DM/DM_VERITY/CRYPTO_SHA256,已由
  `meta-lubancat/recipes-kernel/linux/files/ota.cfg` 补齐并纳入 CI「内核配置自查」
  断言。**内核项未上板实测,§C1 见分晓。**
