# sstate mirror(Cloudflare R2)

## 为什么种在 CI 而不是本机

没有 uninative 时,sstate 会绑定构建机的发行版——poky 自己的
`conf/distro/include/yocto-uninative.inc` 注释写得很清楚:uninative 存在
就是为了让 sstate feed 不再 "specific to the distro running on the build
machine"。

种和用都在 `ubuntu-latest` 上,发行版天然一致,命中率才有保障。本机种的
sstate 拿到 runner 上大概率大面积 miss。

## 为什么分轮种

GitHub 的 job 上限是 **360 分钟硬顶**(写更大的值会被静默截断,只有
self-hosted 能突破)。冷编一次多半跑不完。

但 Yocto 的构建天然可断点续传,续传介质正是 sstate:

```
第 1 轮  冷编 → 到墙钟上限停 → 推 sstate
第 2 轮  拉 sstate → 接着编 → 再推
...      直到某一轮能一次跑完 = 种满
```

**关键:超时必须由 shell 层的 `timeout` 控制,不能靠 job 超时。** job 被
GitHub 砍掉时后续 step 根本不执行,`if: always()` 也救不回来,那一轮编的
东西全白费。workflow 里 job 给 350 分钟、bitbake 给 260 分钟,差额留给上传。

## 磁盘

GitHub 文档写的 **14 GB 是保证值,不是实际值**。盘总共约 72 GB,50+ GB 被
预装软件占着,起始可用约 22 GB;删掉 android SDK / dotnet / ghc / swift /
CodeQL 等可再腾出约 31 GB,实际能到 45–50 GB。

workflow 的第一个 step 就在做这件事,而且是逐条 `rm`、不用第三方 action——
那类 action 会拿到本 job 的完整上下文,而这里只需要几条 rm。

## 要配的 secrets 与 variables

在仓的 **Settings → Secrets and variables → Actions** 里配。

| 名字 | 类型 | 值 |
|---|---|---|
| `R2_ACCESS_KEY_ID` | secret | R2 API token 的 Access Key ID |
| `R2_SECRET_ACCESS_KEY` | secret | R2 API token 的 Secret Access Key |
| `R2_ENDPOINT` | secret | `https://<account-id>.r2.cloudflarestorage.com` |
| `R2_BUCKET` | variable | bucket 名 |
| `SSTATE_BASE_URL` | variable | bucket 的**公开只读** HTTPS 基址 |

`SSTATE_BASE_URL` 与前面几个是两条不同的通道:

- 上传走 **S3 API + 凭据**(`R2_ENDPOINT` + 两个 key)
- 下载走 **匿名 HTTPS**(`SSTATE_BASE_URL`),因为 bitbake 的
  `SSTATE_MIRRORS` 只会发普通 GET,不会带签名

所以 bucket 需要开公开读。`r2.dev` 那个默认域**有速率限制**,Cloudflare
建议正式用途绑自定义域——具体限额**待查证**,先用 `r2.dev` 跑通,撞到限流
再绑域名。

三个 secret 都没配时 workflow 不会失败,只是跳过上传并发一条 warning——
fork 来的 PR 拿不到 secret,不该因此变红。

## 目录布局

```
<bucket>/
├── sstate/      ← build/sstate-cache 的镜像,SSTATE_MIRRORS 指这里
└── downloads/   ← 源码 tarball,SOURCE_MIRROR_URL 指这里
```

`downloads/` 同步时排除了 `git2/`——那是裸 git 镜像,几万个松散对象,
同步到对象存储代价过高而收益有限。

## 怎么跑第一轮

Actions → build → Run workflow。第一轮必然是冷编,大概率 260 分钟到点也
编不完,这是**预期结果,不是失败**——workflow 会把它判成成功并在 summary
里写明"墙钟到点,本轮未编完"。

第一轮的 summary 会给出两个数,正好回答设计稿 8.2 里的待查证:

- 清理前后的实际可用磁盘
- `sstate-cache` / `downloads` / `tmp` 各占多少

拿到这两个数才谈得上判断这条路划不划算。

## 反向也成立:用 CI 的 sstate 在本机编(已实测)

上面那条"本机种的 sstate 到 runner 上会大面积 miss"讲的是**本机 → runner**。
反过来 **runner → 本机**是通的,2026-09-06 实测:整镜像 5050 个任务里 5006 个
不用重跑,冷启动到出片约 20 分钟。

前提只有一条:**uninative 必须拿得到**。它在则 sstate 不绑定构建机发行版,
CI 那份就能直接用;拿不到而按 `known-issues/yocto-fetch-egress-blocked.md`
关掉它,native 部分的 hash 就跟 CI 对不上,退化成几小时冷编——那条 SOP 是
救火用的,不是常态配置,别顺手写进 local.conf 长期留着。

配置逐项照抄 workflow 的「生成构建配置」那一步,少一项就可能整片 miss:

```sh
MACHINE = "rk3566-lubancat"
DISTRO  = "lubancat"
BB_HASHSERVE = ""                       # 与 CI 一致,否则 unihash 对不上
BB_SIGNATURE_HANDLER = "OEBasicHash"
SSTATE_MIRRORS ?= "file://.* <SSTATE_BASE_URL>/sstate/PATH;downloadfilename=PATH"
SOURCE_MIRROR_URL ?= "<SSTATE_BASE_URL>/downloads/"
INHERIT += "own-mirrors"
```

`SSTATE_BASE_URL` 在仓的 Actions variables 里(`gh api repos/<owner>/<repo>/actions/variables`)。
本地**不要**加 `INHERIT += "rm_work"`:出了问题要进 workdir 看编译产物,
而 rm_work 只多一个任务、不改别人的 hash,去掉它不影响命中。

宿主还需要 `chrpath cpio diffstat gawk lz4 zstd file texinfo`,以及
`en_US.UTF-8` locale。`oe-init-build-env` 引用了未定义的 `BBSERVER`,
包它的脚本别写 `set -u`。

**这条路的价值**:CI 一轮 20–40 分钟,本地改一行重编只要几分钟。树外内核模块
那种"要编到最后才知道对不对"的东西,不在本地过一遍就是拿 CI 当编译器。
