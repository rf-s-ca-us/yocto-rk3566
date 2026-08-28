#!/bin/sh
# 拉取第三方 Yocto layer 到 layers/,按官方渠道、固定在 scarthgap。
# 这些内容永不进本仓 git —— 见 .gitignore。
set -eu

BRANCH=scarthgap
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAYERS=$ROOT/layers

fetch() {
    url=$1
    dst=$LAYERS/$2
    if [ -d "$dst/.git" ]; then
        echo "== update $2"
        git -C "$dst" fetch --depth 1 origin "$BRANCH"
        git -C "$dst" reset --hard FETCH_HEAD
    else
        echo "== clone $2"
        # 上次 clone 中断会留下没有 .git 的残目录,git clone 进非空目录会失败
        rm -rf "$dst"
        git clone --depth 1 --branch "$BRANCH" "$url" "$dst"
    fi
}

mkdir -p "$LAYERS"
fetch https://github.com/yoctoproject/poky.git              poky
fetch https://github.com/openembedded/meta-openembedded.git meta-openembedded
fetch https://github.com/JeffyCN/meta-rockchip.git          meta-rockchip

echo
echo "layer 就位。下一步:"
echo "  . layers/poky/oe-init-build-env"
