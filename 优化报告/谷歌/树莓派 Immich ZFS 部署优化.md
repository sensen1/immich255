# **树莓派5环境下Immich 2.5.5高性能部署与ZFS存储优化深度研究报告**

## **1\. 绪论：边缘计算与新一代资产管理的融合**

随着个人数字资产的爆炸式增长，自托管照片与视频管理解决方案的需求日益迫切。Immich 作为该领域的佼佼者，以其现代化的移动端体验和强大的机器学习功能脱颖而出。然而，随着 Immich 2.5.5 版本的发布，其底层架构——特别是向量数据库的实现——发生了重大变革，从 pgvecto.rs 迁移至 VectorChord 1。这一变化对存储子系统的随机读写性能提出了更为严苛的要求。  
本报告旨在针对树莓派 5（Raspberry Pi 5）这一高性能单板计算机（SBC）平台，提供一份详尽的 Immich 2.5.5 部署与优化指南。树莓派 5 凭借其四核 Cortex-A76 处理器和 PCIe 2.0/3.0 接口的支持，打破了以往 SBC 在 I/O 吞吐量上的瓶颈，使其成为承载 ZFS（Zettabyte File System）这一企业级文件系统的理想微型服务器平台。  
本研究基于用户提供的环境——配备 16GB 内存的树莓派 5，运行 Debian 13 (trixie)，内核版本 6.12，且已在 2TB NVMe 驱动器上建立名为 appdata 的 ZFS 存储池 2。报告将深入探讨如何通过细粒度的 ZFS 数据集（Dataset）划分、参数调优以及 Docker 容器编排的精细化配置，来解决写放大（Write Amplification）、内存争用（Memory Contention）和计算资源调度等核心技术挑战，最终实现一个高可用、高性能且数据安全的自托管媒体中心。

## **2\. 系统架构与硬件环境深度分析**

在进行软件层面的部署之前，必须对底层的硬件架构和操作系统环境进行深入剖析。树莓派 5 的硬件特性直接决定了 ZFS 参数的选取和 Immich 服务容器的资源限制策略。

### **2.1 树莓派 5 的计算与 I/O 特性**

树莓派 5 搭载的博通 BCM2712 SoC 是此次部署的核心计算引擎。其集成的四核 ARM Cortex-A76 处理器主频高达 2.4GHz，相比前代产品在整数运算和浮点运算性能上提升了两到三倍 3。对于 Immich 而言，这意味着系统具备了更为强大的软件转码（Software Transcoding）能力和机器学习推理（Inference）能力。然而，最为关键的架构改进在于其 I/O 子系统。  
BCM2712 首次引入了用户可访问的 PCIe 2.0 x1 接口（可通过配置强制开启 PCIe 3.0），使得 NVMe SSD 的接入成为可能。在传统的 USB 3.0 桥接方案中，SCSI 协议的转换开销和 USB 协议的延迟往往成为 ZFS 性能的掣肘。而在 PCIe 直连模式下，NVMe 驱动器可以直接通过 DMA（直接内存访问）与系统内存交换数据，极大地降低了延迟并提高了吞吐量。这对于 ZFS 的意图日志（ZIL）写入和 L2ARC 读取至关重要。  
用户环境配置了 16GB LPDDR4X-4267 SDRAM 2。在 ZFS 架构中，内存不仅是操作系统的运行空间，更是存储性能的关键加速器——自适应替换缓存（ARC）。16GB 的容量为 ARC 提供了充足的驻留空间，使得热点数据（如 Postgres 的索引页、活跃的缩略图）能够完全加载由于内存中，从而掩盖 NVMe 的物理延迟。

### **2.2 操作系统与 ZFS on Linux (ZoL) 版本特性**

用户所使用的 Debian 13 (trixie) 是 Debian 的测试分支，搭载了 6.12 版本的 Linux 内核 2。这是一个极具前瞻性的选择。内核 6.12 包含了一系列针对 ZFS 兼容性的改进以及对 ARM64 架构的优化。OpenZFS 在 Linux 上的实现（ZoL）已经高度成熟，但在 ARM 架构上，内存屏障（Memory Barrier）和原子操作的开销与 x86 架构有所不同。  
ZFS 的核心优势在于其写时复制（Copy-on-Write, CoW）机制。数据在被覆盖前，新数据会被写入新的块中，指针随之更新。这种机制天然消除了传统 RAID 的“写空洞”风险，并支持瞬间快照。然而，CoW 机制在处理数据库等随机小块写入负载时，如果记录大小（recordsize）配置不当，会引发严重的读-改-写（Read-Modify-Write）循环，导致写放大。Immich 2.5.5 引入的 VectorChord 向量数据库正是典型的随机写入密集型应用，因此，ZFS 的参数调优将是本报告的核心内容。

## **3\. Immich 2.5.5 架构变革与存储需求解析**

Immich 2.5.5 版本并非一次简单的功能迭代，它在底层数据存储架构上进行了重大重构。理解这些变化是设计 ZFS 数据集布局的前提。

### **3.1 向量数据库的演进：从 pgvecto.rs 到 VectorChord**

在早期的 Immich 版本中，面部识别和智能搜索功能依赖于 pgvecto.rs 扩展来存储和检索高维向量数据。2.5.5 版本正式迁移至 VectorChord 1。这一迁移旨在提升大规模向量检索的性能和可扩展性，但也带来了新的存储特征。  
向量索引（如 HNSW \- Hierarchical Navigable Small World 或 IVF \- Inverted File Index）的构建和维护涉及大量的随机内存访问和磁盘写入。当用户上传照片时，机器学习容器会生成嵌入向量（Embeddings），Postgres 数据库需要将这些向量插入到索引结构中。这个过程会导致数据库文件的频繁更新。如果 ZFS 的块大小（recordsize）设置为默认的 128KB，而 Postgres 的页大小（Page Size）为 8KB，那么即使是修改一个向量的细微变动，也会触发 128KB 的物理写入。这种 16 倍的写放大不仅浪费了 PCIe 带宽，还会显著缩短 NVMe SSD 的使用寿命 5。

### **3.2 微服务架构下的 I/O 模式分类**

Immich 作为一个微服务架构应用，其不同组件产生的数据具有截然不同的 I/O 模式（I/O Patterns）。将所有数据存储在同一个 ZFS 数据集中是一种极其低效的做法。我们需要根据 I/O 特征将数据分流：

| 组件名称 | 数据类型 | I/O 模式特征 | 典型文件大小 | 关键性能指标 |
| :---- | :---- | :---- | :---- | :---- |
| **PostgreSQL** | 关系型数据与向量索引 | 极度密集的随机 4K/8K 读写，对延迟极其敏感 | 8KB (Page) | IOPS, Latency |
| **Library (Originals)** | 原始照片与视频 | 顺序写入（上传时），顺序读取（备份或全屏查看时），一次写入多次读取（WORM） | 3MB \- 5GB | Throughput, Compression |
| **Thumbnails** | 生成的缩略图 (WebP/JPEG) | 大量小文件的随机读取，目录元数据操作频繁 | 10KB \- 100KB | Metadata OPS, Latency |
| **Encoded Video** | 转码后的流媒体视频 | 顺序写入，顺序读取，流式传输 | 10MB \- 500MB | Throughput |
| **ML Cache** | 机器学习模型文件 | 启动时读取，运行期间基本静默 | 100MB \- 500MB | Read Latency |

基于上述分析，单一的 appdata 数据集无法同时满足这些相互冲突的需求。因此，必须在 appdata 池下创建嵌套的数据集结构，并对每个数据集应用针对性的 ZFS 属性。

## **4\. ZFS 存储设计与参数调优实战**

本章节将详细阐述如何在现有的 appdata 池上构建优化的数据集层级结构。这一设计旨在最大化树莓派 5 的硬件效能，同时确保 Immich 数据的完整性与存取速度。

### **4.1 数据集层级结构规划**

建议采用以下嵌套数据集结构：

* appdata/immich (根容器，定义通用属性)  
  * appdata/immich/library (存储原始媒体文件)  
  * appdata/immich/postgres (存储数据库文件)  
  * appdata/immich/thumbs (存储缩略图)  
  * appdata/immich/encoded-video (存储转码视频)  
  * appdata/immich/profile (存储用户配置)  
  * appdata/immich/ml-cache (存储模型缓存)  
  * appdata/immich/backups (存储数据库备份)

这种结构不仅便于管理，更重要的是，它允许我们将 ZFS 的 recordsize、compression 和 primarycache 等属性精确匹配到特定的工作负载上。

### **4.2 核心 ZFS 参数调优理论与实践**

#### **4.2.1 Recordsize（记录大小）：性能调优的基石**

ZFS 的 recordsize 决定了文件系统中存储数据的最大逻辑块大小。这是 ZFS 调优中最为关键的参数。

* **PostgreSQL 优化 (recordsize=16k)**： PostgreSQL 默认使用 8KB 的页大小。为了避免前文提到的写放大问题，最直观的做法是将 ZFS recordsize 设为 8KB。然而，业界最佳实践通常建议设置为 **16KB** 7。 **深度解析：** 设置为 16KB 允许 ZFS 尝试将两个 Postgres 页压缩进一个物理块中（如果使用 LZ4 压缩）。如果数据不可压缩，ZFS 会将其存储为 16KB，这仅产生 2 倍的写放大，远优于 128KB 时的 16 倍放大。更重要的是，16KB 的块大小减少了元数据（Metadata）的数量，因为需要追踪的块指针（Block Pointers）比纯 8KB 方案少了一半。对于树莓派这种 CPU 资源相对有限的设备，减少元数据处理开销是提升性能的有效手段。  
* **媒体库优化 (recordsize=1M)**： 对于照片和视频这种大文件，默认的 128KB 记录大小会导致文件被切分成成千上万个块。将 recordsize 提升至 **1MB** 可以显著减少块指针的数量，降低 CPU 在处理大文件时的上下文切换开销，并提高顺序读取的吞吐量 9。此外，更大的块大小通常能带来更好的压缩比（尽管媒体文件本身已经是压缩格式，但对于未压缩的 RAW 格式照片效果显著）。  
* **缩略图优化 (recordsize=64k)**：  
  缩略图通常在 20KB 到 100KB 之间。使用 1MB 的块大小会造成巨大的空间浪费（Slack Space），因为每个文件至少占用一个块。使用 64KB 可以更好地匹配文件大小分布，平衡元数据开销与空间利用率。

#### **4.2.2 Compression（压缩算法）：CPU 与 I/O 的博弈**

* **LZ4**：这是 ZFS 的默认压缩算法，具有极高的压缩和解压速度。对于数据库和一般用途，LZ4 是不二之选，因为它几乎不消耗 CPU 周期，却能有效减少写入磁盘的数据量（实际上提升了 I/O 吞吐量）。  
* **ZSTD (Zstandard)**：ZSTD 提供了接近 GZIP 的压缩率，同时保持了接近 LZ4 的解压速度。树莓派 5 的 Cortex-A76 核心支持 NEON 指令集，能够高效运行 ZSTD。建议在 library 数据集上启用 compression=zstd，以节省昂贵的 NVMe 空间。虽然媒体文件大多已压缩，但 ZFS 压缩可以作用于文件系统元数据和部分未压缩的数据头，且 ZFS 足够智能，若数据不可压缩会直接放弃，不会造成 CPU 浪费。

#### **4.2.3 Atime（访问时间）：必须关闭的特性**

默认情况下，ZFS 会在每次读取文件时更新文件的“访问时间”（atime）。对于 Immich 这样在浏览相册时需要瞬间读取成百上千个缩略图的应用，开启 atime 会将所有的读取操作转化为写入操作，造成巨大的 I/O 风暴。必须将 atime 设置为 off 5。

#### **4.2.4 Logbias（日志偏好）：Latency vs Throughput**

对于数据库数据集，建议设置 logbias=latency。这指示 ZFS 将意图日志（ZIL）记录同步写入到底层存储设备，而不是聚合后再写入。这对于保证数据库事务的原子性和降低提交延迟至关重要。虽然 NVMe 速度很快，但在高并发写入下，保持低延迟比追求极致吞吐量更能提升用户体验。

### **4.3 数据集创建实施指南**

基于上述分析，请在树莓派终端中依次执行以下命令。这些命令假设 appdata 池已挂载（通常在 /appdata 或 /mnt/appdata，本例假设挂载点为 /mnt/appdata，请根据实际情况调整）。

Bash

\# 1\. 创建 Immich 根数据集（继承默认属性，设定通用优化）  
\# xattr=sa: 将扩展属性存储在inode中，提升Linux下的文件操作性能  
sudo zfs create \\  
  \-o compression=lz4 \\  
  \-o atime=off \\  
  \-o xattr=sa \\  
  \-o mountpoint=/mnt/appdata/immich \\  
  appdata/immich

\# 2\. 创建 PostgreSQL 数据集（核心优化：针对随机小块写入）  
\# recordsize=16k: 匹配数据库页大小，消除写放大  
\# logbias=latency: 优化事务提交延迟  
\# primarycache=all: 确保索引和数据都进入 ARC 缓存  
sudo zfs create \\  
  \-o recordsize=16k \\  
  \-o logbias=latency \\  
  \-o primarycache=all \\  
  appdata/immich/postgres

\# 3\. 创建媒体库数据集（核心优化：针对大文件顺序读写）  
\# recordsize=1M: 提升吞吐量，减少元数据开销  
\# compression=zstd: 利用 Pi 5 CPU 能力换取存储空间  
sudo zfs create \\  
  \-o recordsize=1M \\  
  \-o compression=zstd \\  
  appdata/immich/library

\# 4\. 创建缩略图数据集（核心优化：针对大量小文件）  
\# recordsize=64k: 匹配缩略图文件大小分布  
sudo zfs create \\  
  \-o recordsize=64k \\  
  appdata/immich/thumbs

\# 5\. 创建转码视频数据集（核心优化：针对流媒体）  
\# recordsize=1M: 优化视频流的顺序读取  
sudo zfs create \\  
  \-o recordsize=1M \\  
  appdata/immich/encoded-video

\# 6\. 创建其他辅助数据集（使用默认或通用配置）  
sudo zfs create appdata/immich/profile  
sudo zfs create \-o recordsize=128k appdata/immich/ml-cache  
sudo zfs create appdata/immich/backups

**验证步骤：**  
执行 zfs list \-r appdata/immich 确认所有数据集已正确创建并挂载。  
执行 zfs get recordsize appdata/immich/postgres 确认 recordsize 为 16K。

## **5\. 数据库层详细配置与 VectorChord 适配**

在 ZFS 层优化完成后，必须在应用层对 PostgreSQL 进行适配，特别是针对 Immich 2.5.5 的 VectorChord 扩展。

### **5.1 Docker 镜像选择与配置**

Immich 2.5.5 要求使用特定的数据库镜像以支持 VectorChord。通用的 postgres:14 镜像不包含必要的扩展，无法启动应用。根据 2.5.5 的发布说明和最佳实践 1，必须在 docker-compose.yml 中显式指定包含 VectorChord 的镜像标签。  
**镜像标签解析：**  
通常格式为：ghcr.io/immich-app/postgres:14-vectorchordX.X.X-pgvectorX.X.X。  
对于 2.5.5 版本，推荐使用 ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0（具体哈希值请参考官方最新发布的 compose 文件）。

### **5.2 PostgreSQL 参数调优 (针对 16GB RAM)**

虽然 ZFS 的 ARC 会管理大部分缓存，但 Postgres 自身的内存管理也不容忽视。在 docker-compose.yml 的 database 服务中，可以通过 command 覆盖默认配置，或者挂载自定义的 postgresql.conf。  
针对树莓派 5 的 16GB 内存，建议配置如下：

* shared\_buffers: 设置为 **2GB \- 4GB**。虽然通常建议设置为 RAM 的 25%，但在 ZFS 环境下，由于 ARC 也在做缓存（且 ZFS 的 ARC 压缩效率更高），可以适当降低 shared\_buffers，将更多内存留给 ARC。双重缓存（Double Caching）在 ZFS 上是一个复杂的话题，但在 Linux 上，ZFS 的 ARC 通常比 OS 的 Page Cache 更智能 11。  
* work\_mem: 适当增加，以加速复杂查询和向量索引构建。  
* max\_wal\_size: 增加 WAL（Write Ahead Log）的大小（例如 1GB 或 2GB）。这可以减少 Checkpoint 的频率，从而减少写入 NVMe 的频率。配合 ZFS 的 logbias=latency，可以显著提升写入性能。

## **6\. 计算资源管理与硬件加速策略**

树莓派 5 并非全能选手。在 Immich 的应用场景中，视频转码和机器学习是两个计算密集型任务。

### **6.1 视频转码：软件编码的必然选择**

这是一个关键的认知点：**树莓派 5 的 VideoCore VII GPU 目前不具备 H.264 硬件编码能力** 13。它仅支持 HEVC (H.265) 的硬件解码。这意味着，将高码率视频转码为兼容性好的 H.264 格式（Web 播放标准）必须完全依赖 CPU。

* **FFMPEG 配置策略**：在 Immich 的转码设置中，切勿强行开启 vaapi 或 quicksync，这会导致转码失败或容器崩溃。应选择 **Software Encoding (Libx264)**。  
* **性能优化**：  
  * **Preset（预设）**：设置为 ultrafast 或 superfast。这会牺牲一定的压缩率（生成文件稍大），但能大幅降低 CPU 占用，确保在 Pi 5 上也能流畅播放。  
  * **分辨率限制**：建议将转码目标分辨率限制在 720p 或 1080p，避免 4K 转码耗尽 CPU 资源。

### **6.2 机器学习：CPU 推理的效能**

Immich 使用机器学习模型进行 CLIP（语义搜索）和面部识别。

* **硬件加速现状**：Immich 支持的 armnn 后端主要针对 Mali GPU，而 Pi 5 使用的是 VideoCore VII，且缺乏通用的 NPU 驱动支持 Immich 的容器环境。OpenVINO 专用于 Intel 硬件 15。  
* **推荐方案**：使用 **CPU**。树莓派 5 的 Cortex-A76 核心性能强劲，处理数万张照片的索引构建虽然耗时（可能需要数小时至一天），但这是单次投入。后续增量更新几乎无感。  
* **并发控制**：在 Immich 设置中，将机器学习的并发任务数限制为 1 或 2，防止在后台处理时抢占数据库和 Web 服务的 CPU 资源。

### **6.3 内存与 ARC 的博弈：避免 OOM**

这是树莓派 5 部署中最容易被忽视的风险点。ZFS 默认会使用高达 50% 的系统内存作为 ARC（即 8GB）。而 Immich 的多个容器（特别是 Node.js 服务和 ML Python 进程）在重负载下可能消耗 6-8GB 内存。如果两者争抢内存，Linux 的 OOM Killer 可能会杀死数据库进程，导致数据损坏。  
**强制限制 ARC 大小**：  
建议将 ARC 限制为 4GB \- 6GB。这为应用程序预留了充足的 10GB+ 空间。  
**操作命令**（持久化配置）：  
创建 /etc/modprobe.d/zfs.conf 文件并写入：

Bash

options zfs zfs\_arc\_max=4294967296

（注：4294967296 Bytes \= 4GB）。然后执行 sudo update-initramfs \-u 并重启。

## **7\. 部署实施指南：Docker Compose 与环境配置**

本节将整合上述所有优化，提供最终的配置文件模板。

### **7.1 环境配置 (.env)**

用户提供的 example.env 中 DB\_DATA\_LOCATION 默认为 ./postgres 2。这必须修改以指向我们创建的 ZFS 数据集。

Bash

\#.env 文件内容建议  
IMMICH\_VERSION=v2.5.5  
\# 将上传根目录指向 ZFS 根数据集挂载点  
UPLOAD\_LOCATION=/mnt/appdata/immich  
\# 显式指定数据库路径到 ZFS 优化的 postgres 数据集  
DB\_DATA\_LOCATION=/mnt/appdata/immich/postgres  
\# 数据库凭证  
DB\_PASSWORD=your\_strong\_password  
DB\_USERNAME=postgres  
DB\_DATABASE\_NAME=immich

### **7.2 Docker Compose 文件构建**

以下是针对树莓派 5 和 ZFS 优化的 docker-compose.yml。

YAML

name: immich

services:  
  immich-server:  
    container\_name: immich\_server  
    image: ghcr.io/immich-app/immich-server:${IMMICH\_VERSION:-release}  
    \# Pi 5 仅使用 CPU 转码，无需 extends hwaccel 配置文件  
    volumes:  
      \# 映射 ZFS 根目录，其下的 library, thumbs 等子数据集会自动生效  
      \- ${UPLOAD\_LOCATION}:/usr/src/app/upload  
      \- /etc/localtime:/etc/localtime:ro  
    env\_file:  
      \-.env  
    ports:  
      \- 2283:2283  
    depends\_on:  
      \- redis  
      \- database  
    restart: always

  immich-machine-learning:  
    container\_name: immich\_machine\_learning  
    image: ghcr.io/immich-app/immich-machine-learning:${IMMICH\_VERSION:-release}  
    \# 同样仅使用 CPU，无需硬件加速配置  
    volumes:  
      \# 将模型缓存映射到 ZFS ml-cache 数据集  
      \- model-cache:/cache  
    env\_file:  
      \-.env  
    restart: always

  redis:  
    container\_name: immich\_redis  
    image: docker.io/redis:6.2-alpine@sha256:905c4ee67b8e0aa955331960d2aa745781e6bd89afc44a8584bfd13bc890f0ae  
    restart: always

  database:  
    container\_name: immich\_postgres  
    \# 关键：使用支持 VectorChord 的特定镜像  
    image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23  
    environment:  
      POSTGRES\_PASSWORD: ${DB\_PASSWORD}  
      POSTGRES\_USER: ${DB\_USERNAME}  
      POSTGRES\_DB: ${DB\_DATABASE\_NAME}  
      \# 开启数据校验和，作为 ZFS 校验的补充  
      POSTGRES\_INITDB\_ARGS: '--data-checksums'  
    volumes:  
      \# 直接映射 ZFS postgres 数据集  
      \- ${DB\_DATA\_LOCATION}:/var/lib/postgresql/data  
    restart: always

volumes:  
  \# 定义 model-cache 卷指向 ZFS 数据集路径  
  model-cache:  
    driver: local  
    driver\_opts:  
      type: none  
      o: bind  
      device: /mnt/appdata/immich/ml-cache

**关键路径说明**：  
在上述配置中，我们将 UPLOAD\_LOCATION 映射到了 /usr/src/app/upload。由于我们在 ZFS 中已经创建了 /mnt/appdata/immich/library、/mnt/appdata/immich/thumbs 等子目录（实质上是挂载点），Docker 容器在写入 /usr/src/app/upload/library 时，实际上是直接写入了配置了 recordsize=1M 的 ZFS 数据集中。这种透传机制确保了 ZFS 的属性能够精准作用于对应的文件类型。

## **8\. 运维与备份策略**

### **8.1 备份方案：应用一致性与 ZFS 快照的结合**

单纯依赖 ZFS 快照备份运行中的数据库是不安全的，可能导致数据不一致。推荐的备份工作流如下：

1. **应用层导出**：使用 Immich 自带的备份功能（或编写脚本调用 pg\_dump），将数据库转储为 SQL 文件，保存至 /mnt/appdata/immich/backups。  
2. **文件系统快照**：在数据库转储完成后，对整个 appdata/immich 递归创建 ZFS 快照。  
   * 命令：zfs snapshot \-r appdata/immich@backup\_2024\_xx\_xx  
3. **异地复制**：使用 zfs send/recv 将快照增量发送到另一台服务器或外部硬盘，实现真正的 3-2-1 备份。

### **8.2 定期维护**

* **Scrub（数据清洗）**：每月运行一次 zpool scrub appdata，利用 ZFS 的校验和机制扫描并自动修复静默数据损坏（Bit Rot）。  
* **Trim（修剪）**：由于是 NVMe SSD，定期执行 zpool trim appdata 可以通知 SSD 主控释放未使用的块，保持写入性能和延长寿命。

## **9\. 结论**

通过在树莓派 5 上实施精细化的 ZFS 存储分层策略，我们不仅解决了 Immich 2.5.5 引入的 VectorChord 数据库带来的写放大挑战，还充分释放了 NVMe SSD 的性能潜力。将 PostgreSQL 的 recordsize 锁定为 16KB，配合媒体库的 1MB 大块存储，是在嵌入式平台上平衡 IOPS 与吞吐量的最优解。虽然树莓派 5 在硬件转码方面存在局限，但通过合理的软件编码设置和内存资源管控（ARC 限制），完全可以构建一个企业级稳定、响应迅速的家庭媒体中心。此方案将硬件性能压榨到了极致，同时也为数据的长久保存提供了坚实的保障。

#### **引用的著作**

1. Upgrading \- Immich Docs, 访问时间为 二月 9, 2026， [https://docs.immich.app/install/upgrading](https://docs.immich.app/install/upgrading)  
2. README.md  
3. Running Immich on a Raspberry Pi 5 – Better Than Google Photos on Cheap Hardware \- Reddit, 访问时间为 二月 9, 2026， [https://www.reddit.com/r/immich/comments/1p5e1ge/running\_immich\_on\_a\_raspberry\_pi\_5\_better\_than/](https://www.reddit.com/r/immich/comments/1p5e1ge/running_immich_on_a_raspberry_pi_5_better_than/)  
4. Pre-existing Postgres \- Immich Docs, 访问时间为 二月 9, 2026， [https://docs.immich.app/administration/postgres-standalone](https://docs.immich.app/administration/postgres-standalone)  
5. PostgreSQL and ZFS filesystem \- Bun, 访问时间为 二月 9, 2026， [https://bun.uptrace.dev/postgres/tuning-zfs-aws-ebs.html](https://bun.uptrace.dev/postgres/tuning-zfs-aws-ebs.html)  
6. Everything I've seen on optimizing Postgres on ZFS \- VADOSWARE, 访问时间为 二月 9, 2026， [https://vadosware.io/post/everything-ive-seen-on-optimizing-postgres-on-zfs-on-linux/](https://vadosware.io/post/everything-ive-seen-on-optimizing-postgres-on-zfs-on-linux/)  
7. Disadvantages of using ZFS recordsize 16k instead of 128k \- Server Fault, 访问时间为 二月 9, 2026， [https://serverfault.com/questions/1117662/disadvantages-of-using-zfs-recordsize-16k-instead-of-128k](https://serverfault.com/questions/1117662/disadvantages-of-using-zfs-recordsize-16k-instead-of-128k)  
8. ZFS Recordsize and Postgres \- read amplification? : r/zfs \- Reddit, 访问时间为 二月 9, 2026， [https://www.reddit.com/r/zfs/comments/10vjrum/zfs\_recordsize\_and\_postgres\_read\_amplification/](https://www.reddit.com/r/zfs/comments/10vjrum/zfs_recordsize_and_postgres_read_amplification/)  
9. ZFS Dataset Hierarchy | Data Hoarder Edition \- b3n.org, 访问时间为 二月 9, 2026， [https://b3n.org/zfs-hierarchy/](https://b3n.org/zfs-hierarchy/)  
10. Updating postgres : r/immich \- Reddit, 访问时间为 二月 9, 2026， [https://www.reddit.com/r/immich/comments/1m78vxe/updating\_postgres/](https://www.reddit.com/r/immich/comments/1m78vxe/updating_postgres/)  
11. most impactful Postgres settings to tweak when host has lots of free RAM \- Stack Overflow, 访问时间为 二月 9, 2026， [https://stackoverflow.com/questions/30328861/most-impactful-postgres-settings-to-tweak-when-host-has-lots-of-free-ram](https://stackoverflow.com/questions/30328861/most-impactful-postgres-settings-to-tweak-when-host-has-lots-of-free-ram)  
12. PostgreSQL Vector Search: VectorChord vs. pgvector vs. pgvectorscale, 访问时间为 二月 9, 2026， [https://blog.vectorchord.ai/vector-search-over-postgresql-a-comparative-analysis-of-memory-and-disk-solutions](https://blog.vectorchord.ai/vector-search-over-postgresql-a-comparative-analysis-of-memory-and-disk-solutions)  
13. IMPOSSIBLE\] FFmpeg and v4l2m2m on the Raspberry Pi 5: "Could not find a valid device", 访问时间为 二月 9, 2026， [https://forums.raspberrypi.com/viewtopic.php?t=364180](https://forums.raspberrypi.com/viewtopic.php?t=364180)  
14. Raspberry Pi 5 transcoding, 访问时间为 二月 9, 2026， [https://forums.raspberrypi.com/viewtopic.php?t=357999](https://forums.raspberrypi.com/viewtopic.php?t=357999)  
15. Hardware-Accelerated Machine Learning \- Immich Docs, 访问时间为 二月 9, 2026， [https://docs.immich.app/features/ml-hardware-acceleration](https://docs.immich.app/features/ml-hardware-acceleration)