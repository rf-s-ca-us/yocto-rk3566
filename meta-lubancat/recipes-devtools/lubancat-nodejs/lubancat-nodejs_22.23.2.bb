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

INHIBIT_PACKAGE_STRIP = "1"
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
}

FILES:${PN} = "/usr/local/lib/nodejs /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx"
