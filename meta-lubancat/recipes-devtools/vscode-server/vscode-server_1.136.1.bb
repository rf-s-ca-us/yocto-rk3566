SUMMARY = "vscode-server + 远端 CLI,钉 commit a44adf7f(拍板 1.1)"
DESCRIPTION = "Remote-SSH 首连要两件:远端 CLI code-<commit>(bootstrap 先找它)与 server 包\
(Stable-<commit>/server)。只装 server 时首连仍会触发一次 CLI 下载,两件同 commit 一起钉\
才能兑现'直连不下载'。update.code.visualstudio.com 的 URL 无文件名,用 downloadfilename 显式指定。\
微软预编译件按专有件对待:仓与镜像分发物里只有 URL+sha256,EULA 分发条款的风险已在 \
docs/hermes-native/design.html 第 7 节记录。"

LICENSE = "Proprietary"
LIC_FILES_CHKSUM = "file://vscode-server-linux-arm64/LICENSE;md5=8d09a4b68713590a3ed601f545e79e29"

SRC_URI = "https://update.code.visualstudio.com/commit:a44adf7f53e00964ab890f9f8758a334f1fc15bc/server-linux-arm64/stable;downloadfilename=vscode-server-a44adf7f-linux-arm64.tar.gz \
           https://update.code.visualstudio.com/commit:a44adf7f53e00964ab890f9f8758a334f1fc15bc/cli-alpine-arm64/stable;downloadfilename=vscode-cli-a44adf7f-alpine-arm64.tar.gz"
SRC_URI[sha256sum] = "87d479525d9e02c2139af824ac339a71122a9b2cea79ef03abb74f0fc574d631"
SRC_URI[sha256sum] = "aec9dfd6e17c8a29febd7e95aef2767832e68101f398faf151826b820d73636f"

COMPATIBLE_HOST = "aarch64.*-linux"
S = "${WORKDIR}"

INHIBIT_PACKAGE_STRIP = "1"
INSANE_SKIP:${PN} += "already-stripped ldflags arch"

# 摆放位置即客户端"已预装"的唯一判定:cli/servers/Stable-<commit>/server 内容齐即可
do_install() {
	install -d ${D}/root/.vscode-server/cli/servers/Stable-a44adf7f53e00964ab890f9f8758a334f1fc15bc/server
	cp -a ${WORKDIR}/vscode-server-linux-arm64/. \
		${D}/root/.vscode-server/cli/servers/Stable-a44adf7f53e00964ab890f9f8758a334f1fc15bc/server/
	# CLI tar 内是单文件 code(musl 静态,无顶层目录),bitbake 已解到 WORKDIR
	install -m 0755 ${WORKDIR}/code ${D}/root/.vscode-server/code-a44adf7f53e00964ab890f9f8758a334f1fc15bc
	# 属主归零:do_unpack 非 root 解包把文件属主重置为构建用户(GH runner 是
	# uid 1001,归档元数据是否 0/0 无关),cp -a 把这次 chown 记进 pseudo,
	# package_write_rpm 的 getpwuid 映射不到即 KeyError(hermes-python round 4
	# CI 实证同一机制)。install 出的 code 是新建文件,本就 root,一并覆盖无害。
	chown -R root:root ${D}/root/.vscode-server
}

FILES:${PN} = "/root/.vscode-server"

# server 自带的 node 与 13 个 native 模块动态链 libstdc++.so.6 / libgcc_s.so.1
# (readelf 预扫实证:node 及 node-pty/kerberos/sqlite3/spdlog/vsda 等 .node);
# 本包未跳过 file-rdeps,提供者必须进 RDEPENDS。包名取自 pinned poky(b2c16f1e):
# gcc-runtime.inc FILES:libstdc++ = "${libdir}/libstdc++.so.*";
# libgcc.inc PACKAGES 含主包 ${PN}=libgcc(libgcc_s.so.1 走默认 FILES:${PN})。
RDEPENDS:${PN} += "libstdc++ libgcc"

# 树内 4 个可执行的 #!/bin/bash 脚本:out/vs/base/node/cpuUsage.sh 与
# extensions/ms-vscode.js-debug/.../terminateProcess.sh 服务端运行时真会拉起,
# jschardet scripts 两个是随包的 0775。file-rdeps 对可执行脚本硬查 shebang
# 解释器(npm completion.sh round 5 实证),提供者 bash 必须进 RDEPENDS。
# katex 源码自带 3 个 0775 的 perl 字体工具(makeBlacker/makeFF/mapping.pl,
# shebang "#! /usr/bin/perl"),同理需要 perl 提供者 /usr/bin/perl。
# env 形态 shebang(env node x14、env python3 x4、env sh x4)被 file-rdeps
# 忽略(insane.bbclass 忽略表含 /usr/bin/env;hermes-python 全 env 树 round 4
# QA 通过实证);katex Makefile 的 #!gmake 是 0644 非可执行,不记依赖。
RDEPENDS:${PN} += "bash perl"
