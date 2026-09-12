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
}

FILES:${PN} = "/root/.vscode-server"
