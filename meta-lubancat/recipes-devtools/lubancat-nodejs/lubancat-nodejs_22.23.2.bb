SUMMARY = "Node.js 22 LTS aarch64 官方预编译(hermes 运行时依赖)"
DESCRIPTION = "加 lubancat- 前缀:meta-oe 已有同名 PN 的 nodejs recipe(源码构建 20.x),\
同名会互相压制。取 22 不取 26:上游 install.sh 自管的 Node 26 是浮动 latest-v26.x(无 hash pin),\
与公开仓红线冲突;22.23.2 是官方 SHASUMS256 可钉死、且在目标板实跑验证过的版本\
(单进程 RSS 峰值约 430MB),满足上游系统 Node 门槛 22.22+。vscode-server 自带独立 node,互不影响。"

LICENSE = "MIT & ISC & Apache-2.0 & BSD-3-Clause"
LIC_FILES_CHKSUM = "file://LICENSE;md5=b195f4ea4368177a2fd84b879f09cba8"

SRC_URI = "https://nodejs.org/dist/v22.23.2/node-v22.23.2-linux-arm64.tar.xz;downloadfilename=node-v22.23.2-linux-arm64.tar.xz"
SRC_URI[sha256sum] = "fff4078c5def658577f92c88db7db3bc0072924bfb93fe52c1e744a54e94abb8"

COMPATIBLE_HOST = "aarch64.*-linux"
S = "${WORKDIR}/node-v22.23.2-linux-arm64"

# 预编译件统一语义(vscode-server round 7 同源问题):strip 与调试分离是
# package.py 两个独立门,INHIBIT_PACKAGE_STRIP 不覆盖后者——不关 DEBUG_SPLIT,
# objcopy --only-keep-debug / --add-gnu-debuglink 照跑,后者会改写上游字节。
# 本树纯 aarch64(file 实扫仅 bin/node 一个 ELF),但官方 node 自带 debug_info
# 未 strip,分离等于拆出并重分发上游调试件;原样进来原样出去,不做。
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"
INHIBIT_SYSROOT_STRIP = "1"
INSANE_SKIP:${PN} += "already-stripped ldflags libdir"

do_install() {
	install -d ${D}/usr/local/lib/nodejs
	cp -a ${S} ${D}/usr/local/lib/nodejs/
	# 官方包内 bin/npm 本就是相对 symlink(../lib/node_modules/npm/bin/npm-cli.js),
	# cp -a 原样保留;这里只把三个入口链进 PATH
	install -d ${D}/usr/local/bin
	ln -sf ../lib/nodejs/node-v22.23.2-linux-arm64/bin/node ${D}/usr/local/bin/node
	ln -sf ../lib/nodejs/node-v22.23.2-linux-arm64/bin/npm ${D}/usr/local/bin/npm
	ln -sf ../lib/nodejs/node-v22.23.2-linux-arm64/bin/npx ${D}/usr/local/bin/npx
	# 属主归零:官方 tarball 内文件 uid/gid 就是 1001/1001(tar --numeric-owner 实证),
	# 非 root 解包后属主仍是构建用户 uid,cp -a 把 chown 记进 pseudo,package_write_rpm
	# 的 getpwuid 映射不到即 KeyError(round 4 CI 在 hermes-python 上实证同一机制)。
	chown -R root:root ${D}/usr/local/lib/nodejs
}

FILES:${PN} = "/usr/local/lib/nodejs /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx"

# bin/node 动态链 libstdc++.so.6 / libgcc_s.so.1(readelf 预扫实证;发行树内无
# .so/.a,dev-so/staticdev 无涉)。包名取自 pinned poky(b2c16f1e):gcc-runtime.inc
# FILES:libstdc++ = "${libdir}/libstdc++.so.*";libgcc.inc 主包 ${PN}=libgcc。
RDEPENDS:${PN} += "libstdc++ libgcc"

# npm 自带 completion.sh(0755)的 shebang 是 #!/bin/bash,file-rdeps 对可执行
# 脚本硬查 shebang 解释器,提供者必须是包名 bash(round 5 CI 实证)。bin/npm、
# bin/npx 两个包装脚本(0755)是 #!/usr/bin/env bash,QA 虽忽略 env 形态,
# 运行时跑 npm/npx 同样要 bash。同树 node-gyp 的 macOS_Catalina_acid_test.sh
# 是 0644 的 bash shebang,rpmdeps 不为非可执行脚本记依赖,一并被 bash 覆盖。
RDEPENDS:${PN} += "bash"
