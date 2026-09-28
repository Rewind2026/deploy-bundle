# COLLECT_PLANNING.md - 镜像机选型与离线包构建指南

> 目标读者: 交付方/实施方的打包工程师
> 用途: 在公司内网**有外网的镜像机**上，把 MySQL 8 + Tomcat 9 + JDK 8 + 系统依赖
> 打成一个能离线拷贝的 deploy-bundle 包，再交到客户现场。

## 1. 总流程

```
┌──────────────────────┐                              ┌──────────────────────┐
│  公司镜像机(有外网)│                              │  客户机器(无外网)   │
│  OS: 与客户机同 family│                              │  OS: 任意已支持 family │
└──────────┬───────────┘                              └──────────▲───────────┘
           │                                                     │
           ▼                                                     │
   bash collect.sh                                                  │
   --family=rhel8-line                                              │
   --arch=x86_64                                                    │
           │                                                       │
           │ 产物:                                                 │
           │   packages/<FAMILY>/<ARCH>/{jdk,mysql,tomcat,rpms,debs}/  │
           │   LICENSES/                                            │
           │   packages/<FAMILY>/<ARCH>/manifest.tsv                │
           │                                                       │
           └────  U盘 / 内网 / 网闸  ────────────────────────────→ │
                                                                  │
                                                          sudo bash installer.sh --auto
```

**关键点**:
- **collect.sh 必须在有外网的镜像机上跑**
- **installer.sh 必须在客户的离线机器上跑**
- 两端可以**完全不同的 OS family / arch**，只要中间传递的 `packages/<FAMILY>/<ARCH>/` 覆盖目标机

## 2. 镜像机选型

### 2.1 选型原则

**镜像机的 family + arch 必须 = 客户机器的 family + arch** (一一对应)。

举例: 客户是 Kylin V10 SP3 x86_64 → 镜像机必须是 RHEL/CentOS 8 系 x86_64。

### 2.2 5 family x 3 arch 的镜像机清单

| 客户 OS | 客户 family | 客户 arch | 镜像机选择 | 镜像机验证命令 |
|--------|------------|----------|------------|----------------|
| CentOS 7 / RHEL 7 / Kylin V10 SP1-SP2 / openEuler 20.03 | rhel7-line | x86_64 | CentOS 7.9 x86_64 最小安装 | `cat /etc/redhat-release` |
| CentOS 8 / RHEL 8 / Rocky 8 / Anolis 8 / openEuler 24.03 / Kylin V10 SP3 | rhel8-line | x86_64 | Rocky Linux 8.10 x86_64 | `cat /etc/redhat-release` |
| CentOS 9 / RHEL 9 / Rocky 9 / openEuler 22.03 / Kylin V11 | openeuler-line | x86_64 | Rocky 9.x 或 openEuler 22.03 | `cat /etc/redhat-release` |
| Ubuntu 18.04+ / Debian 10+ / Deepin 20+ / Kylin Desktop V10 | deb-line | x86_64 | Debian 12 或 Ubuntu 22.04 | `cat /etc/debian_version` |
| UOS 1050 / UOS 1070 桌面 | deb-line | x86_64 | UOS 1050/1070 桌面版 | `cat /etc/os-release` |
| UOS 1050 / 1060 / 1070 服务器 | rhel8-line | x86_64 | UOS 服务器版 (apt-rpm) | `cat /etc/os-release` |
| 任何 aarch64 客户机 | 上表任意 family | aarch64 | 上表对应 family 的 aarch64 镜像机 | `uname -m` |
| 飞腾/海光 ARM 国产化 | rhel8-line | aarch64 | 飞腾 FT-2000+/64 + Kylin V10 SP3 | `uname -m` |
| loongarch64 | loongarch | loongarch64 | **不支持** (v2.0 计划) | - |

**最少镜像机数量**: 5 台 (4 x x86_64 + 1 x aarch64) 足以支撑 90% 的客户场景。

### 2.3 镜像机最小配置

```
CPU: 2 核
内存: 4 GB
磁盘: 10 GB 空闲
网络: 能访问外网
工具: sudo / curl / openssl / createrepo_c (rhel) / dpkg-dev (deb)
```

**预装工具**:
```bash
# rhel 7
sudo yum install -y createrepo_c rpm-build yum-utils

# rhel 8 / 9 / openEuler
sudo dnf install -y createrepo_c rpm-build dnf-utils

# deb / UOS
sudo apt-get install -y dpkg-dev
```

### 2.4 公司网络出网限制

设置环境变量走内部镜像:
```bash
export DEPLOY_MIRROR_ADOPTIUM=https://mirrors.tuna.tsinghua.edu.cn/Adoptium
export DEPLOY_MIRROR_MYSQL=https://mirrors.huaweicloud.com/mysql
export DEPLOY_MIRROR_TOMCAT=https://mirrors.huaweicloud.com/apache/tomcat
```

## 3. 打包流程

### 3.1 一台镜像机 = 一个 family + 一个 arch

```bash
cd /opt/deploy-bundle

# 第一次跑: dry-run 看看计划
sudo bash scripts/collect.sh --family=rhel8-line --arch=x86_64 --dry-run

# 正式跑
sudo bash scripts/collect.sh --family=rhel8-line --arch=x86_64
# 输出:
#   packages/rhel8-line/x86_64/jdk/OpenJDK8U-jdk_x64_linux_hotspot_8u504-b01.tar.gz  (99MB)
#   packages/rhel8-line/x86_64/mysql/mysql-8.0.36-linux-glibc2.28-x86_64.tar.xz      (400MB)
#   packages/rhel8-line/x86_64/tomcat/apache-tomcat-9.0.91.tar.gz                   (12MB)
#   packages/rhel8-line/x86_64/rpms/libaio-*.rpm                                     (60MB)
#   LICENSES/
```

### 3.2 多 family 多 arch 的工作流

```bash
# 在镜像机 A (rhel8-line/x86_64) 上:
scp deploy-bundle.tar.gz deploy@mirror-b:/opt/deploy-bundle.tar.gz

# 在镜像机 B (rhel8-line/aarch64) 上:
tar xzf /opt/deploy-bundle.tar.gz -C /opt/
cd /opt/deploy-bundle
sudo bash scripts/collect.sh --family=rhel8-line --arch=aarch64

# 两边产物合并:
rsync -av mirror-a:/opt/deploy-bundle/packages/rhel8-line/x86_64/    packages/rhel8-line/x86_64/
rsync -av mirror-b:/opt/deploy-bundle/packages/rhel8-line/aarch64/  packages/rhel8-line/aarch64/
rsync -av --ignore-existing mirror-a:/opt/deploy-bundle/LICENSES/    LICENSES/
```

### 3.3 离线包结构 (最终交付给客户的形态)

```
deploy-bundle-v1.0-rhel8-x86_64.tar.gz            # 一个 family + arch ≈ 1.0 GB
├── installer.sh
├── VERSION
├── scripts/
├── configs/
├── ansible/
├── docs/
├── tests/
├── packages/
│   └── rhel8-line/
│       └── x86_64/
│           ├── jdk/
│           │   └── OpenJDK8U-jdk_x64_linux_hotspot_8u504-b01.tar.gz
│           ├── mysql/
│           │   ├── mysql-8.0.36-linux-glibc2.28-x86_64.tar.xz
│           │   └── mysql-8.0.36-linux-glibc2.17-x86_64.tar.xz
│           ├── tomcat/
│           │   └── apache-tomcat-9.0.91.tar.gz
│           ├── rpms/
│           │   ├── libaio-*.rpm
│           │   └── repodata/
│           └── manifest.tsv
└── LICENSES/
    ├── OpenJDK-License.txt
    ├── MySQL-License.txt
    └── Tomcat-License.txt
```

### 3.4 打包校验

```bash
# 1. 完整性
bash tests/test_bundle.sh   # 应 100% 通过

# 2. 模拟离线安装
sudo bash installer.sh --dry-run
```

### 3.5 复用 / 升级

- **同一 family + arch 升级**: 再次跑 collect.sh，已下载的文件会自动跳过
- **JDK 8 / MySQL 8 / Tomcat 9 小版本号变化**: 指定 `--jdk=8u512` 重跑
- **添加新 family**: 在对应 family 的镜像机上跑 collect.sh

## 4. 跨 family 依赖差异

| family | 必装依赖 |
|--------|---------|
| rhel7-line | libaio, numactl-libs, libnsl |
| rhel8-line | libaio, numactl-libs, libxcrypt-compat |
| openeuler-line | libaio, numactl-libs |
| deb-line | libaio1, libnuma1, libssl3 |

## 5. 检查清单

- [ ] `packages/<family>/<arch>/jdk/` 下至少有 1 个 JDK tar.gz
- [ ] `packages/<family>/<arch>/mysql/` 下至少有 1 个 MySQL tar.xz (glibc2.28 必须有)
- [ ] `packages/<family>/<arch>/tomcat/` 下至少有 1 个 Tomcat tar.gz
- [ ] `packages/<family>/<arch>/rpms/` 或 `debs/` 至少有 libaio / numactl
- [ ] `LICENSES/` 含 OpenJDK / MySQL / Tomcat / 依赖库 LICENSE
- [ ] `tests/test_bundle.sh` 100% 通过
- [ ] 在该镜像机上用 `installer.sh --dry-run` 探测正常
- [ ] 真机 (family+arch 一致) 上至少跑过一次端到端

## 6. 进一步阅读

- 兼容矩阵: [COMPATIBILITY.md](./COMPATIBILITY.md)
- 客户现场部署: [INSTALL.md](./INSTALL.md)
- FAQ: [FAQ.md](./FAQ.md)