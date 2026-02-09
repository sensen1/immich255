# Immich 2.5.5 在树莓派 5 上的优化部署指南

## 系统环境

- 树莓派 5 (16GB RAM)
- NVMe 2TB (ext4 系统盘)
- ZFS pool: appdata (1.7TB)
- OS: Debian GNU/Linux 13 (trixie)
- Kernel: 6.12.62+rpt-rpi-2712
- Docker: 29.1.5

## 一、ZFS 数据集创建和优化

### 1.1 数据集设计原则

根据 Immich 的数据访问特点，我们将数据分为几类，并为每种类型设置不同的 ZFS 参数：

| 数据类型 | 数据集 | recordsize | 压缩 | cache策略 | 用途 |
|---------|--------|------------|------|-----------|------|
| 数据库 | appdata/immich/db | 128K | lz4 | all | 低延迟随机读写 |
| 媒体文件 | appdata/immich/library | 1M | lz4 | metadata | 大文件顺序读写 |
| ML模型缓存 | appdata/immich/ml | 128K | lz4 | all | 快速读取模型文件 |

### 1.2 数据集创建命令

```bash
# 创建 Immich 主数据集结构
sudo zfs create -o compression=lz4 -o atime=off -o xattr=sa appdata/immich

# 数据库数据集 - 需要低延迟随机 IO
sudo zfs create -o recordsize=128K \
    -o logbias=latency \
    -o primarycache=all \
    -o sync=standard \
    appdata/immich/db

# 媒体文件数据集 - 大文件顺序读写
sudo zfs create -o recordsize=1M \
    -o compression=lz4 \
    -o atime=off \
    -o primarycache=metadata \
    appdata/immich/library

# ML 模型缓存数据集 - 小文件，需要快速读取
sudo zfs create -o recordsize=128K \
    -o compression=lz4 \
    -o atime=off \
    -o primarycache=all \
    appdata/immich/ml

# 设置数据集权限
sudo chmod 750 /appdata/immich
sudo chown -R $(whoami):$(whoami) /appdata/immich

# 验证创建结果
zfs list -r appdata/immich
```

### 1.3 ZFS 参数说明

**通用参数：**
- `compression=lz4`: 启用 LZ4 压缩，CPU 开销低，压缩率高
- `atime=off`: 禁用访问时间更新，减少写操作
- `xattr=sa`: 使用系统属性存储扩展属性，提高性能

**数据库专用：**
- `recordsize=128K`: PostgreSQL 的默认页大小，优化随机 IO
- `logbias=latency`: 优先考虑延迟而非吞吐量
- `primarycache=all`: 缓存所有数据，加速数据库访问
- `sync=standard`: 保证数据持久性

**媒体文件专用：**
- `recordsize=1M`: 大记录大小，优化大文件顺序读写
- `primarycache=metadata`: 只缓存元数据，节省 ARC 空间

## 二、Immich 部署配置

### 2.1 准备工作

```bash
# 创建部署目录
mkdir -p ~/immich-app
cd ~/immich-app

# 下载 docker-compose.yml 和 .env 文件（使用已提供的文件）
# 将 docker-compose.yml 和 .env 文件放到此目录
```

### 2.2 环境变量配置 (.env)

```bash
# 媒体文件存储路径
UPLOAD_LOCATION=/appdata/immich/library

# 数据库存储路径
DB_DATA_LOCATION=/appdata/immich/db

# 时区设置（根据实际情况修改）
TZ=Asia/Shanghai

# Immich 版本（固定为 2.5.5）
IMMICH_VERSION=v2.5.5

# 数据库密码（请修改为强密码）
DB_PASSWORD=YourSecurePasswordHere

# 数据库配置（通常不需要修改）
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
```

### 2.3 启动服务

```bash
# 启动容器
docker compose up -d

# 查看日志
docker compose logs -f

# 查看容器状态
docker compose ps
```

## 三、性能优化建议

### 3.1 ZFS ARC 调整

针对 16GB RAM 的系统，可以调整 ZFS ARC 大小：

```bash
# 设置 ARC 最大为 8GB（总内存的一半）
echo 8589934592 | sudo tee /sys/module/zfs/parameters/zfs_arc_max

# 永久设置（编辑 /etc/modprobe.d/zfs.conf）
echo "options zfs zfs_arc_max=8589934592" | sudo tee /etc/modprobe.d/zfs.conf
```

### 3.2 Docker 资源限制

如果需要限制资源使用，可以在 docker-compose.yml 中添加：

```yaml
services:
  immich-server:
    # ... 其他配置
    deploy:
      resources:
        limits:
          memory: 8G
        reservations:
          memory: 4G

  database:
    # ... 其他配置
    deploy:
      resources:
        limits:
          memory: 2G
        reservations:
          memory: 1G
```

### 3.3 PostgreSQL 优化

ZFS 数据库数据集已经针对 PostgreSQL 做了优化，包括：
- `recordsize=128K` 匹配 PostgreSQL 页大小
- `logbias=latency` 优化延迟
- `primarycache=all` 缓存所有数据

Immich 的 PostgreSQL 镜像已经包含了针对 SSD 的优化配置。

## 四、维护和备份

### 4.1 备份数据库

```bash
# 手动备份
docker compose exec -T database pg_dumpall -U postgres > backup.sql

# 定期备份（添加到 crontab）
0 2 * * * cd ~/immich-app && docker compose exec -T database pg_dumpall -U postgres > /appdata/immich/backup/immich_$(date +\%Y\%m\%d).sql
```

### 4.2 ZFS 快照

```bash
# 创建快照
sudo zfs snapshot appdata/immich@backup-$(date +%Y%m%d)

# 列出快照
sudo zfs list -t snapshot -r appdata/immich

# 恢复快照
sudo zfs rollback appdata/immich@backup-YYYYMMDD
```

### 4.3 清理旧数据

```bash
# 清理 Docker 占用空间
docker system prune -a

# 清理 ZFS 快照（保留最近 30 天）
sudo zfs list -t snapshot -r appdata/immich | grep -E "appdata/immich@backup-[0-9]{8}" | awk '{print $1}' | while read snap; do
    date=$(echo $snap | grep -oE "[0-9]{8}$")
    snap_date=$(date -d "${date:0:4}-${date:4:2}-${date:6:2}" +%s)
    thirty_days_ago=$(date -d "30 days ago" +%s)
    if [ $snap_date -lt $thirty_days_ago ]; then
        sudo zfs destroy $snap
    fi
done
```

## 五、故障排查

### 5.1 检查服务状态

```bash
# 检查容器状态
docker compose ps

# 检查容器日志
docker compose logs immich-server
docker compose logs database
docker compose logs immich-machine-learning
```

### 5.2 检查 ZFS 状态

```bash
# 检查 ZFS pool 状态
sudo zpool status appdata

# 检查数据集使用情况
sudo zfs list -r appdata/immich

# 检查 ZFS 性能
sudo zpool iostat 1 5
```

### 5.3 常见问题

**问题 1: 数据库连接失败**
- 检查数据库容器是否正常运行
- 检查 ZFS 数据集权限
- 查看 database 容器日志

**问题 2: 媒体文件上传失败**
- 检查 library 数据集挂载点
- 检查磁盘空间：`df -h /appdata/immich/library`
- 检查文件权限

**问题 3: 性能较慢**
- 检查 ZFS ARC 使用情况：`cat /proc/spl/kstat/zfs/arcstats`
- 检查磁盘 IO：`iostat -x 1 5`
- 考虑调整 ARC 大小

## 六、升级步骤

```bash
# 1. 备份数据
sudo zfs snapshot appdata/immich@pre-upgrade-$(date +%Y%m%d)
docker compose exec -T database pg_dumpall -U postgres > backup.sql

# 2. 更新 .env 文件中的 IMMICH_VERSION

# 3. 拉取新镜像
docker compose pull

# 4. 重启容器
docker compose up -d

# 5. 检查状态
docker compose ps
docker compose logs -f
```

## 七、参考资源

- [Immich 官方文档](https://docs.immich.app/)
- [Immich GitHub](https://github.com/immich-app/immich)
- [OpenZFS 文档](https://openzfs.github.io/openzfs-docs/)
- [ZFS 性能调优指南](https://github.com/openzfs/zfs)
