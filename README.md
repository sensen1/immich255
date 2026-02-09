### immich 2.55 部署测试

对255版本的部署做配置测试

目前官方最新的版本是 2.55

目前比较稳定的历史版本是 2.41

但是从发展的角度，可能2.55是已经目前全新部署的适合的版本，所以尝试一下 2.55的 部署

### 部署目标情况

immich要部署到一台树莓派5. 内存 16G ， 采用 nvme 2T 作为系统盘， / 文件系统是 ext4， 然后 这个盘上 分出了 1.7T 作为 zfs的 appdata pool， 用于存放immich的数据。

### 系统docker方面的情况

docker方面 采用的是 29.1.5 版本。 docker在 29 版本之后也发生了一些转变。

目前的 /etc/docker/daemon.json  配置如下


```
 "features": {
    "containerd-snapshotter": true
  },

```

然后 docker info 的相关部分信息


```
  sensen@raspberrypi:~ $ sudo docker info
Client: Docker Engine - Community
 Version:    29.1.5
 Context:    default
 Debug Mode: false
 Plugins:
  buildx: Docker Buildx (Docker Inc.)
    Version:  v0.31.1
    Path:     /usr/libexec/docker/cli-plugins/docker-buildx
  compose: Docker Compose (Docker Inc.)
    Version:  v5.0.2
    Path:     /usr/libexec/docker/cli-plugins/docker-compose

Server:
 Containers: 1
  Running: 0
  Paused: 0
  Stopped: 1
 Images: 1
 Server Version: 29.1.5
 Storage Driver: overlayfs
  driver-type: io.containerd.snapshotter.v1
 Logging Driver: local
 Cgroup Driver: systemd
 Cgroup Version: 2
 Plugins:
  Volume: local
  Network: bridge host ipvlan macvlan null overlay
  Log: awslogs fluentd gcplogs gelf journald json-file local splunk syslog

  Kernel Version: 6.12.62+rpt-rpi-2712
 Operating System: Debian GNU/Linux 13 (trixie)
 OSType: linux
 Architecture: aarch64
 CPUs: 4
 Total Memory: 15.84GiB

 ```

 