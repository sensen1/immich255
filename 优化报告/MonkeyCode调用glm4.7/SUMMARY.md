# Immich 2.5.5 树莓派 5 优化部署总结

## 📋 部署概览

本文档提供了在树莓派 5 上优化部署 Immich 2.5.5 的完整方案，包括 ZFS 数据集优化和 Docker Compose 配置。

### 系统配置
- **硬件**: 树莓派 5 (16GB RAM)
- **存储**: NVMe 2TB (ext4 系统盘 + 1.7TB ZFS appdata pool)
- **操作系统**: Debian GNU/Linux 13 (trixie)
- **内核版本**: 6.12.62+rpt-rpi-2712
- **Docker 版本**: 29.1.5

## 🚀 快速开始

### 方法 1: 使用部署脚本（推荐）

```bash
# 1. 运行 ZFS 数据集创建脚本
./deploy-zfs.sh

# 2. 修改 .env 配置文件
# - 修改 DB_PASSWORD 为强密码
# - 修改 TZ 为你的时区（如 Asia/Shanghai）

# 3. 启动 Immich
docker compose up -d
```

### 方法 2: 手动创建 ZFS 数据集

```bash
# 主数据集
sudo zfs create -o compression=lz4 -o atime=off -o xattr=sa appdata/immich

# 数据库数据集
sudo zfs create -o recordsize=128K -o logbias=latency -o primarycache=all -o sync=standard appdata/immich/db

# 媒体文件数据集
sudo zfs create -o recordsize=1M -o compression=lz4 -o atime=off -o primarycache=metadata appdata/immich/library

# ML 模型缓存数据集
sudo zfs create -o recordsize=128K -o compression=lz4 -o atime=off -o primarycache=all appdata/immich/ml

# 设置权限
sudo chmod 750 /appdata/immich
sudo chown -R $(whoami):$(whoami) /appdata/immich

# 启动服务
docker compose up -d
```

## 📊 ZFS 数据集优化说明

### 数据集结构

```
appdata/
└── immich/                  # 主数据集
    ├── db/                  # PostgreSQL 数据库
    ├── library/             # 媒体文件存储
    └── ml/                  # 机器学习模型缓存
```

### 优化参数详解

| 参数 | 数据库 | 媒体文件 | ML缓存 | 说明 |
|------|--------|----------|--------|------|
| **recordsize** | 128K | 1M | 128K | 匹配访问模式 |
| **compression** | lz4 | lz4 | lz4 | 节省空间 |
| **atime** | off | off | off | 减少写操作 |
| **primarycache** | all | metadata | all | 缓存策略 |
| **logbias** | latency | - | - | 优先延迟 |
| **sync** | standard | - | - | 保证持久性 |

### 为什么这些参数对 Immich 重要

1. **数据库 (recordsize=128K)**: PostgreSQL 的默认页大小，随机 IO 性能最优
2. **媒体文件 (recordsize=1M)**: 大文件顺序读写，减少元数据开销
3. **ML 缓存 (recordsize=128K)**: 模型文件通常较小，平衡读写性能
4. **compression=lz4**: CPU 开销低，压缩率高，适合照片和视频
5. **primarycache=all/metadata**: 根据数据类型优化 ARC 缓存使用

## ⚙️ 环境变量配置

### 必须修改的变量

```bash
# 数据库密码 - 必须修改为强密码！
DB_PASSWORD=YourSecurePasswordHere

# 时区设置 - 根据你的位置修改
TZ=Asia/Shanghai
```

### 已配置的路径

```bash
# 媒体文件存储路径
UPLOAD_LOCATION=/appdata/immich/library

# 数据库存储路径
DB_DATA_LOCATION=/appdata/immich/db

# Immich 版本（固定）
IMMICH_VERSION=v2.5.5
```

## 🔧 额外性能优化

### ZFS ARC 调整

```bash
# 设置 ARC 最大值为 8GB（总内存的一半）
echo 8589934592 | sudo tee /sys/module/zfs/parameters/zfs_arc_max

# 永久设置
echo "options zfs zfs_arc_max=8589934592" | sudo tee /etc/modprobe.d/zfs.conf
```

### 查看 ZFS 性能

```bash
# 查看 ARC 使用情况
cat /proc/spl/kstat/zfs/arcstats

# 查看磁盘 IO
sudo zpool iostat 1 5

# 查看数据集性能
sudo zfs list -r appdata/immich
```

## 📝 维护操作

### 数据库备份

```bash
# 手动备份
docker compose exec -T database pg_dumpall -U postgres > backup.sql

# 自动备份（添加到 crontab）
0 2 * * * cd ~/immich-app && docker compose exec -T database pg_dumpall -U postgres > /appdata/immich/backup/immich_$(date +\%Y\%m\%d).sql
```

### ZFS 快照

```bash
# 创建快照
sudo zfs snapshot appdata/immich@backup-$(date +%Y%m%d)

# 列出快照
sudo zfs list -t snapshot -r appdata/immich

# 恢复快照
sudo zfs rollback appdata/immich@backup-YYYYMMDD

# 删除旧快照（保留 30 天）
sudo zfs list -t snapshot -r appdata/immich | grep -E "appdata/immich@backup-[0-9]{8}" | awk '{print $1}' | while read snap; do
    date=$(echo $snap | grep -oE "[0-9]{8}$")
    snap_date=$(date -d "${date:0:4}-${date:4:2}-${date:6:2}" +%s)
    thirty_days_ago=$(date -d "30 days ago" +%s)
    if [ $snap_date -lt $thirty_days_ago ]; then
        sudo zfs destroy $snap
    fi
done
```

### 清理 Docker 资源

```bash
# 清理未使用的镜像和容器
docker system prune -a
```

## 🐛 故障排查

### 检查容器状态

```bash
# 查看所有容器状态
docker compose ps

# 查看特定容器日志
docker compose logs immich-server
docker compose logs database
docker compose logs immich-machine-learning
```

### 常见问题

**问题 1: 容器无法启动**

```bash
# 检查端口占用
sudo netstat -tlnp | grep 2284

# 检查数据集挂载
df -h /appdata/immich

# 查看详细日志
docker compose logs --tail=100
```

**问题 2: 数据库连接失败**

```bash
# 检查数据库容器
docker compose exec database psql -U postgres -d immich

# 检查 ZFS 数据集权限
ls -la /appdata/immich/db
```

**问题 3: 性能较慢**

```bash
# 检查 ARC 使用情况
cat /proc/spl/kstat/zfs/arcstats | grep -E "size|c_max"

# 检查磁盘 IO
iostat -x 1 5

# 调整 ARC 大小
echo 10737418240 | sudo tee /sys/module/zfs/parameters/zfs_arc_max  # 10GB
```

## 🔄 升级 Immich

```bash
# 1. 备份
sudo zfs snapshot appdata/immich@pre-upgrade-$(date +%Y%m%d)
docker compose exec -T database pg_dumpall -U postgres > backup.sql

# 2. 更新版本号
# 编辑 .env 文件，修改 IMMICH_VERSION

# 3. 拉取新镜像
docker compose pull

# 4. 重启服务
docker compose up -d

# 5. 验证
docker compose ps
docker compose logs -f
```

## 📚 参考资源

- [Immich 官方文档](https://docs.immich.app/)
- [Immich GitHub](https://github.com/immich-app/immich)
- [Immich 环境变量参考](https://docs.immich.app/install/environment-variables)
- [OpenZFS 文档](https://openzfs.github.io/openzfs-docs/)
- [ZFS 性能调优](https://github.com/openzfs/zfs)

## ✅ 部署检查清单

在完成部署后，请检查以下项目：

- [ ] ZFS 数据集已创建（appdata/immich, db, library, ml）
- [ ] 数据集权限已正确设置（750, owner: user:group）
- [ ] .env 文件中的 DB_PASSWORD 已修改为强密码
- [ ] TZ 时区已设置为正确的值
- [ ] 所有容器正常运行（docker compose ps）
- [ ] 可以访问 Immich Web UI (http://raspberrypi:2284)
- [ ] ZFS ARC 大小已根据内存调整（8GB 或更高）
- [ ] 备份计划已设置（数据库备份和 ZFS 快照）

## 📞 获取帮助

如果遇到问题：

1. 查看容器日志：`docker compose logs -f`
2. 检查 ZFS 状态：`sudo zpool status appdata`
3. 访问 [Immich GitHub Issues](https://github.com/immich-app/immich/issues)
4. 加入 [Immich Discord](https://discord.immich.app)

---

**部署完成后，请记得：**
1. 修改默认密码
2. 设置定期备份
3. 监控系统性能
4. 定期更新 Immich
