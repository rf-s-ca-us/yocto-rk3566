#!/bin/sh
# 拉取第三方 Yocto layer 到 layers/,按官方渠道、固定在已验证的提交。
# 这些内容永不进本仓 git —— 见 .gitignore。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAYERS=$ROOT/layers

fetch() {
    url=$1
    dst=$LAYERS/$2
    revision=$3

    echo "== sync $2"
    # init 能接管上次拉取中断留下的残目录,也让任意 SHA 仍可保持浅拉取。
    git init -q "$dst"
    if git -C "$dst" remote get-url origin >/dev/null 2>&1; then
        git -C "$dst" remote set-url origin "$url"
    else
        git -C "$dst" remote add origin "$url"
    fi
    git -C "$dst" fetch --depth 1 origin "$revision"
    git -C "$dst" reset --hard FETCH_HEAD
}

mkdir -p "$LAYERS"
# 升级时先确认候选提交来自上游 scarthgap,并用独立构建目录通过 bitbake -p;
# 然后只替换对应 SHA,避免 CI 在同一仓库提交上随上游分支漂移。
fetch https://github.com/yoctoproject/poky.git              poky                b2c16f1e69130558574e1363aff944647fa9cd11
fetch https://github.com/openembedded/meta-openembedded.git meta-openembedded   bec755063a8b5da65df626f5749496aadaa4f4bb
fetch https://github.com/JeffyCN/meta-rockchip.git          meta-rockchip       0d2f157767af62c43acca2f82b8d51cb99aa257a
# 官方仓在 git.yoctoproject.org,GitHub 上没有官方镜像(yoctoproject/
# meta-virtualization 是 404,能搜到的 GitHub 副本都是第三方 fork)。
fetch https://git.yoctoproject.org/meta-virtualization      meta-virtualization f980aefbc8b3eeafb8d144e7fdac3c3b701a4fea
# meta-ros 一个 git 仓里装着三个 layer(meta-ros-common / meta-ros2 /
# meta-ros2-jazzy),三个都要进 BBLAYERS。scarthgap 分支上 Jazzy 是 full 支持
# (到 2028-04),Humble / Kilted / Lyrical 也在同一个分支里,只登记 Jazzy 那层。
fetch https://github.com/ros/meta-ros.git                   meta-ros            336ec2aaeede7f6f2d7d305cde0426f8dbc14984

echo
echo "layer 就位。下一步:"
echo "  . layers/poky/oe-init-build-env"
