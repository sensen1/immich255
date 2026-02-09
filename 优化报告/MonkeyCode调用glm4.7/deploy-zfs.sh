#!/bin/bash

# Immich 2.5.5 快速部署脚本 - 树莓派 5 优化版

set -e

echo "=== Immich 2.5.5 快速部署脚本 ==="
echo "目标平台: 树莓派 5 (16GB RAM, NVMe)"
echo ""

# 检查是否为 root 用户
if [ "$EUID" -eq 0 ]; then
    echo "请不要使用 root 用户运行此脚本"
    exit 1
fi

# 检查 ZFS pool 是否存在
echo "检查 ZFS pool..."
if ! zfs list appdata >/dev/null 2>&1; then
    echo "错误: 找不到 appdata ZFS pool"
    exit 1
fi
echo "appdata pool 存在"
echo ""

# 创建 ZFS 数据集
echo "创建 ZFS 数据集..."

# 主数据集
if ! zfs list appdata/immich >/dev/null 2>&1; then
    echo "创建 appdata/immich 主数据集..."
    sudo zfs create -o compression=lz4 -o atime=off -o xattr=sa appdata/immich
else
    echo "appdata/immich 已存在，跳过创建"
fi

# 数据库数据集
if ! zfs list appdata/immich/db >/dev/null 2>&1; then
    echo "创建 appdata/immich/db 数据库数据集..."
    sudo zfs create -o recordsize=128K \
        -o logbias=latency \
        -o primarycache=all \
        -o sync=standard \
        appdata/immich/db
else
    echo "appdata/immich/db 已存在，跳过创建"
fi

# 媒体文件数据集
if ! zfs list appdata/immich/library >/dev/null 2>&1; then
    echo "创建 appdata/immich/library 媒体文件数据集..."
    sudo zfs create -o recordsize=1M \
        -o compression=lz4 \
        -o atime=off \
        -o primarycache=metadata \
        appdata/immich/library
else
    echo "appdata/immich/library 已存在，跳过创建"
fi

# ML 模型缓存数据集
if ! zfs list appdata/immich/ml >/dev/null 2>&1; then
    echo "创建 appdata/immich/ml ML 模型缓存数据集..."
    sudo zfs create -o recordsize=128K \
        -o compression=lz4 \
        -o atime=off \
        -o primarycache=all \
        appdata/immich/ml
else
    echo "appdata/immich/ml 已存在，跳过创建"
fi

echo ""
echo "设置数据集权限..."
sudo chmod 750 /appdata/immich
sudo chown -R $(whoami):$(whoami) /appdata/immich

echo ""
echo "验证数据集创建结果..."
zfs list -r appdata/immich

echo ""
echo "设置 ZFS ARC 最大值为 8GB..."
ARC_MAX_SIZE=8589934592
echo $ARC_MAX_SIZE | sudo tee /sys/module/zfs/parameters/zfs_arc_max >/dev/null

# 检查是否已有 zfs.conf
if [ ! -f /etc/modprobe.d/zfs.conf ]; then
    echo "创建 /etc/modprobe.d/zfs.conf..."
    echo "options zfs zfs_arc_max=$ARC_MAX_SIZE" | sudo tee /etc/modprobe.d/zfs.conf >/dev/null
else
    echo "/etc/modprobe.d/zfs.conf 已存在，请手动添加以下内容："
    echo "options zfs zfs_arc_max=$ARC_MAX_SIZE"
fi

echo ""
echo "=== ZFS 数据集创建完成 ==="
echo ""
echo "下一步："
echo "1. 修改 .env 文件中的 DB_PASSWORD（必须修改为强密码）"
echo "2. 根据需要修改 TZ 时区设置"
echo "3. 运行: docker compose up -d"
echo ""
echo "注意: 请确保 docker-compose.yml 和 .env 文件在同一目录下"
