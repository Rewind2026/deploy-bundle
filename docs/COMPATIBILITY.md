# 兼容性矩阵 (COMPATIBILITY.md)

本表回答: 某个具体 OS 能不能用 deploy-bundle 部署？需要哪一份 family 的包？

## 1. 系统家族分类

deploy-bundle 把所有目标 Linux 归为 5 个家族:

| family | 包含系统 | glibc | 包格式 |
|--------|---------|-----------|--------|
| `rhel7-line` | CentOS 7 / RHEL 7 / Rocky 7 / AlmaLinux 7 / Kylin V10 SP1-SP2 / openEuler 20.03 | 2.17 | RPM |
| `rhel8-line` | CentOS 8 / RHEL 8 / Rocky 8 / AlmaLinux 8 / RHEL 9 / Rocky 9 / CentOS Stream 8-9 / openEuler 24.03 / Anolis OS 8 / TencentOS Server 3-4 / openCloudOS 8 | 2.28 | RPM |
| `openeuler-line` | openEuler 22.03 / openEuler 20.03 LTS SP3+ / Kylin V11 | 2.34 | RPM |
| `deb-line` | Ubuntu 18.04+ / Debian 10+ / UOS 1050 / UOS 1070 / Deepin 20+ / Kylin Desktop V10 SP3 | 2.27+ | DEB |
| `loongarch` | （预留） | - | - |

**检测逻辑**: `scripts/precheck.sh` 中 `detect_os()` 函数。
Kylin/UOS 专项: `scripts/detect_kylin_uos.sh`。

## 2. 架构矩阵

| arch | family 支持情况 |
|------|---------------|
| `x86_64` | 全部 4 家族 |
| `aarch64` | rhel8-line / openeuler-line / deb-line |
| `loongarch64` | 阶段 3 不支持 |

## 3. JDK 8 兼容性

| 来源 | 兼容性 | 授权 | 备注 |
|------|--------|------|------|
| Adoptium Temurin 8u412+ | **首选** | GPLv2 + Classpath Exception | x86_64 / aarch64 官方支持 |
| OpenJDK 8 (系统自带) | 回退 | GPLv2 | 仅当 Temurin 不可用 |
| 国产 JDK (Bisheng/Loongson) | 备选 | 各异 | 客户强制要求时使用 |

> **注意**: JDK 8u321+ 移除了 3DES_EDE_CBC 等老 cipher。deploy-bundle 已注入补丁 (`configs/java.security`)。

## 4. MySQL 8 兼容性

| OS glibc | 适用 tarball |
|----------|------------|
| 2.17 (CentOS 7 / Kylin V10 SP1-SP2) | glibc2.17 |
| 2.28 (CentOS 8 / openEuler / Anolis) | glibc2.28 |
| 2.31+ (Debian 11 / Ubuntu 20.04) | glibc2.28 兼容 |

**认证插件双支持**:
- `caching_sha2_password` (MySQL 8 默认)
- `mysql_native_password` (老客户端兼容) — 创建 `admin@localhost` 后备账户

**运行时依赖白名单**:
- `rhel7-line`: libaio、numactl-libs、libnsl
- `rhel8-line`: libaio、numactl-libs、libxcrypt-compat
- `openeuler-line`: libaio、numactl-libs
- `deb-line`: libaio1、libnuma1、libssl3

## 5. Tomcat 9 兼容性

| Tomcat 版本 | JDK 8 | JDK 11 | JDK 17 |
|-----------|-------|--------|--------|
| 9.0.50+ | OK | OK | OK |
| 9.0.91 (推荐) | OK | OK | OK |

**Connector**: NIO (默认)，跨 CPU 架构兼容，无需 tcnative。APR/tcnative **未启用**。

## 6. 安全特性兼容

| 特性 | 支持情况 |
|------|---------|
| SELinux Enforcing | OK (仅 mysqld_t / tomcat_t permissive) |
| SELinux Permissive / Disabled | OK |
| AppArmor Enforcing | OK (tomcat 目录 complain) |
| firewalld | OK |
| ufw | OK |
| iptables | OK |
| 无防火墙 | OK (跳过) |

## 7. 已验证的国产化 OS 列表

| OS | 版本 | family | arch | 验证 |
|----|------|--------|------|---------|
| 银河麒麟 Kylin | V10 SP3 | rhel8-line | x86_64 | OK |
| 银河麒麟 Kylin | V10 SP3 | rhel8-line | aarch64 | OK |
| 银河麒麟 Kylin | V10 SP1 | rhel7-line | x86_64 | OK |
| 银河麒麟 Kylin | V11 | openeuler-line | x86_64 | 已识别，待真机验证 |
| 统信 UOS | 1050 | deb-line | x86_64 | OK |
| 统信 UOS | 1070 | deb-line | x86_64 | OK |
| openEuler | 22.03 | openeuler-line | x86_64 | OK |
| openEuler | 20.03 | rhel7-line | x86_64 | OK |
| 龙蜥 Anolis OS | 8 | rhel8-line | x86_64 | OK |
| 阿里云 Anolis OS | 23 | rhel8-line | x86_64 | OK |
| CentOS | 7 / 8 / 9 | rhel7/8-line | x86_64 | OK |
| RHEL | 7 / 8 / 9 | rhel7/8-line | x86_64 | OK |
| Ubuntu | 18.04 / 20.04 / 22.04 | deb-line | x86_64 | OK |
| Debian | 10 / 11 | deb-line | x86_64 | OK |
| Deepin | 20 | deb-line | x86_64 | OK |

## 8. 不支持场景

| 场景 | 替代方案 |
|------|---------|
| 客户无 systemd (init.d) | 前台命令启动 |
| 客户无 sudo 仅 root | 改 installer.sh 去 EUID 检查 |
| 客户不允许 /opt 写入 | `TARGET_BASE` 切其他目录 |
| 数据目录必须非 /var/lib/mysql | 改 `TARGET_DATA_DIR`，需额外配 SELinux |
| 3306 已被占用且不能停 | `--mysql-port=3307` |
| loongarch64 | 手动提供龙芯 JDK + 通用二进制 MySQL |

## 8.1 aarch64 验证矩阵

| 探测项 | x86_64 | aarch64 | 备注 |
|--------|--------|---------|------|
| `uname -m` → `ARCH=aarch64` | OK | OK | - |
| 5 家族映射 | OK | OK | Kylin/UOS/openEuler/Anolis |
| `/proc/cpuinfo` | OK | OK (已修) | aarch64 字段 `Features :` |

| 组件 | x86_64 | aarch64 | 备注 |
|------|--------|---------|------|
| Adoptium Temurin 8 | OK | OK | collect_jdk.sh |
| Apache Tomcat 9 | OK | OK | Java 与 arch 无关 |
| MySQL 8 glibc2.28 | OK | OK (官方) | `mysql-8.0.36-linux-glibc2.28-aarch64.tar.xz` |
| MySQL 8 glibc2.17 | OK | (官方未发布) | 缺失自动跳过 |

| 步骤 | x86_64 | aarch64 | 备注 |
|------|--------|---------|------|
| update-alternatives | OK | OK (已修) | 加 `--slave javac` / `--slave jar` |
| MySQL init | OK | OK | 通用二进制 |
| systemd unit | OK | OK | 绝对路径 |

**国产 CPU 适配**:
- 华为鲲鹏 920 / 916 (aarch64): OK
- 飞腾 FT-2000+/64 / S2500 (aarch64): OK
- 海光 Hygon C86 7285 (x86_64): 走 x86 路径；早期缺 AVX2 已告警
- 兆芯 KH-30000 (x86_64): OK

## 8.2 Kylin / UOS 专项矩阵

针对客户用得最多的 Kylin 和 UOS，做了专项探测脚本 `scripts/detect_kylin_uos.sh`。

### a. 麒麟 Kylin — 版本与 family 映射

| Kylin 版本 | /etc/.kyinfo milestone | 探测后 OS_FAMILY | MySQL glibc |
|-----------|---------------------------|------------------|------------|
| 桌面 V10 SP1 | `Desktop-V10-SP1-...` | rhel7-line | 2.17 |
| 桌面 V10 SP2 | `Desktop-V10-SP2-...` | rhel8-line | 2.28 |
| **桌面 V10 SP3** | `Desktop-V10-SP3-General-Release-2303/2403/2503` | **rhel8-line** | 2.28 |
| 服务器 V10 SP1 | `Server-V10-SP1-...` | rhel7-line | 2.17 |
| 服务器 V10 SP2 | `Server-V10-SP2-...` | rhel8-line | 2.28 |
| **服务器 V10 SP3** | `Server-V10-SP3-General-Release-2303/2403/2503` | **rhel8-line** | 2.28 |
| 服务器 V10 SP3 Host | `Host-V10-SP3-...` | rhel8-line | 2.28 |
| 服务器 V10 2309b | `Server-V10-2309B-...` | rhel8-line | 2.28 |
| **服务器 V11** | `Server-V11-2403/2503-...` | **openeuler-line** | 2.28 |
| 桌面 V11 | `Desktop-V11-2603-...` | openeuler-line | 2.28 |
| 申威版 (sw_64) | 自定义里程碑 | rhel8-line | 2.28 |

### b. 统信 UOS — 版本与 family 映射

| UOS 版本 | ID | variant | 探测后 OS_FAMILY |
|---------|-----|---------|------------------|
| 桌面专业版 V20 (1050) | `uos` 或 `uniontech` | desktop | deb-line |
| 桌面专业版 V20 (1060) | `uos` 或 `uniontech` | desktop | deb-line |
| **桌面专业版 V20 (1070)** | `uos` 或 `uniontech` | desktop | **deb-line** |
| 桌面 V25 | `uos` | desktop | deb-line |
| **服务器 V20 (1070e-AMD64)** | `uniontech` | server | **openeuler-line** |
| 服务器 V20 (1070e-ARM64) | `uniontech` | server | openeuler-line |
| 服务器 V20 (1070a-AMD64) | `uniontech` | server | openeuler-line |
| 服务器 V20 (1070-LoongArch64) | `uniontech` | server | loongarch |
| 服务器 V20 (1070-SW64) | `uniontech` | server | rhel8-line |

### c. 探测优先级

1. 读取 `/etc/.kyinfo` (Kylin 私有，**最权威**)
2. 读取 `/etc/os-release` 的 ID / VERSION_ID
3. 读取 `/usr/lib/os-version` (UOS 1070+ 私有)
4. 探测 `/etc/yum.repos.d/` (UOS apt-rpm vs apt-deb)
5. 检查 `dde-session` (UOS 桌面 fallback)
6. 兜底用 `uname -m` 和 `ldd --version`

### d. 现场必跑 (首次 UOS/Kylin 部署)

```bash
bash scripts/precheck.sh
grep -E '^(KYLIN_UOS_|OS_FAMILY)' /tmp/deploy-bundle.detect
bash installer.sh --dry-run
bash installer.sh --auto --only=install
bash scripts/healthcheck.sh
```

### e. 已知特殊场景

| 场景 | 处理 |
|------|------|
| Kylin V10 SP1 (glibc 2.17) | 自动选 glibc2.17 tarball |
| 麒麟 V10 SP3 2503 | OK |
| UOS 服务器 apt-rpm 系 | fallback openeuler-line |
| UOS 桌面 1070 缺 mariadb-libs | collect_deb_deps 自动打包 |
| 麒麟 V11 (glibc 2.38) | glibc2.28 tarball 兼容 |
| 申威 (sw_64) | rhel8-line |
| 龙芯 loongarch64 Kylin V10 | 当前分到 rhel8-line，mysqld 可能跑不起来 |

## 9. 已知小毛病

| OS / 组件 | 现象 | 处理 |
|----------|------|------|
| openEuler 22.03 + Tomcat 启动阻塞 | jdk.u.random 熵不足 | 注入 `securerandom.source=file:/dev/./urandom` |
| Kylin V10 SP1 + mariadb-libs | MySQL 8 安装冲突 | cleanup_old.sh 自动 dnf swap |
| UOS 1050 + MySQL 8 初始化慢 | 缺 libaio1 | collect_deb_deps 自动打包 |
| RHEL 9 + 老 war 应用 | JDK 8u321+ 移除 3DES | java.security 补丁已注入 |