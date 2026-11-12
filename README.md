id: /root/.trae-cn-server/bin/stable-d654d294a690adb43b5bb35d5b37adf9f292cee0-debian10/modules/ai-agent/libselinux.so.1: no version information available (required by id)
# deploy-bundle

> 离线部署 MySQL 8.4 LTS + Tomcat 9 + JDK 1.8 到国产化 Linux（银河麒麟 Kylin V10/V11、统信 UOS 1050/1070、openEuler 20.03/22.03/24.03、龙蜥 Anolis OS 8/23 等）的自包含脚本套件。
>
> 支持架构：x86_64 / aarch64（loongarch 支持已移除）。

---

## 仓库里有什么 / 没有什么

| 目录 / 文件 | 内容 | 是否在仓库 |
| --- | --- | --- |
| installer.sh | 主入口（参数详见 --help） | 是 |
| scripts/ | 探测、采集、安装、回滚、健康检查等子脚本 | 是 |
| configs/ | my.cnf / server.xml / *.service / java.security 模板 | 是 |
| docs/ | PRD / PLAN / FAQ / INSTALL / COMPATIBILITY / COLLECT_PLANNING | 是 |
| ansible/ | 同款部署能力的 Ansible 编排（deploy.yml / inventory.example） | 是 |
| tests/ | 沙箱自测（test_bundle.sh） | 是 |
| LICENSES/deb-line/... | 离线采集到的 deb 包许可证文本（合规用） | 是 |
| packages/<FAMILY>/<ARCH>/ | 真实离线包（MySQL/Tomcat/JDK tarball + deb/rpm） | 否 — 见 packages/README.md |

二进制离线包不应该走 git 仓库分发：本仓库只发布脚本与文档，
离线包由 scripts/collect_*.sh 在镜像机上现场采集、按
packages/<FAMILY>/<ARCH>/{jdk|mysql|tomcat|debs|rpms}/ 目录组织后
整体打包交付。详见 docs/COLLECT_PLANNING.md。

---

## 工作流（两阶段）

联网镜像机 → collect.sh 采集 → 打包 → U盘 → 客户机 installer.sh --auto

更多细节见 docs/INSTALL.md 和 docs/FAQ.md 的 Q0。

---

## 快速上手（5 分钟跑通）

```bash
# 1) 克隆到镜像机（联网）
git clone https://github.com/Rewind2026/deploy-bundle.git
cd deploy-bundle

# 2) 在镜像机上采集离线包
sudo TARGET_FAMILY=openeuler-line TARGET_ARCH=x86_64 bash scripts/collect.sh

# 版本可在 8.4.x / 9.x / 8.x 范围内通过环境变量调整（硬性范围外会被拒绝）：
#   MYSQL_VERSION=8.4.6  TOMCAT_VERSION=9.0.91  JDK_VERSION=8  sudo TARGET_FAMILY=... bash scripts/collect.sh

# 3) 把整个目录/打包产物拷到 U 盘，带到客户机

# 4) 在客户机（断网）上一键部署
sudo bash installer.sh --auto
```

详见 docs/INSTALL.md。

---

## 兼容性矩阵（精简版）

完整版本见 docs/COMPATIBILITY.md。

| 家族 | 代表 OS | glibc | 包管理器 |
| --- | --- | --- | --- |
| rhel7-line | CentOS 7 / Kylin V10 SP1 | 17 | rpm/yum |
| rhel8-line | CentOS 8 / RHEL 8 / Kylin V10 SP2-SP3 | 18 | rpm/dnf |
| openeuler-line | openEuler 20.03/22.03/24.03 / Kylin V11 / UOS Server | 28 | rpm/dnf |
| deb-line | Ubuntu 20.04/22.04/24.04 / Debian 11/12 / UOS Desktop | 12~14 | dpkg/apt |
| loongarch | — | — | 支持已移除（仅 x86_64 / aarch64） |

麒麟 / 统信专项适配见 scripts/detect_kylin_uos.sh + docs/COMPATIBILITY.md §8.2。

---

## 关键行为约定（实施人员必读）

| 项 | 约定 |
| --- | --- |
| 安装路径 | JDK `/opt/jdk`、MySQL `/opt/mysql`、Tomcat `/opt/tomcat`，数据目录 `/var/lib/mysql` |
| 应用目录 | Tomcat appBase：deb 系 `/var/lib/tomcat/webapps`，其余 `/var/lib/tomcats/webapps`（`/opt/tomcat/webapps` 是指向它的软链） |
| MySQL 账号 | 固定密码 `ywj02402570687`（root 与 admin 同密码，`--mysql-password=PW` 可覆盖）；`root@%`（caching_sha2）、`admin@%`（mysql_native_password，兼容 Navicat 等老客户端）均可远程 |
| 密码策略 | 部署时自动降级 `validate_password` 强度（密码不符合默认策略也能设置成功） |
| JVM 参数 | `-Xms1024M -Xmx4096M` + G1GC（写死在 `/opt/tomcat/bin/setenv.sh`，现场可直接改） |
| Tomcat 服务 | `Type=forking`（PID 文件模式）；优雅停机 `/opt/tomcat/bin/tomcat-stop.sh` 最多等 60s 再强杀 |
| 防火墙 | 默认永久关闭（firewalld/ufw/iptables 自适应）——现场可能改 Tomcat 端口 |
| 清理策略 | 按"新系统部署"原则：系统自带 JDK（**含 1.8.x**）、MariaDB、MySQL（含仓库版 mysql-community）**全部卸载**；mariadb-libs 用 `rpm -e --nodeps` 单包卸载（不连带卸 postfix/cronie）；旧数据目录搬入 `/opt/deploy-bundle-backups/` 后重新初始化 |
| 幂等重装 | 同机重复执行 `installer.sh --auto` 自动停用本工具注册的 mysqld/tomcat 并重装覆盖；**MySQL 8.0+ 数据目录（含 mysql.ibd）保留复用**，业务数据不丢 |
| SQL/WAR 导入 | `app/sql/*.sql` 按文件名顺序导入 nkw 库（utf8mb3_general_ci）；`app/war/*.war` 解压到 webapps/ROOT 并重启 tomcat；库已有表时跳过导入（幂等） |
| MySQL 就绪等待 | deploy_app 阶段连接 MySQL 最多等待 120s（systemd active ≠ 端口 ready，低配机器首次启动慢） |

---

## 子脚本速查

| 脚本 | 作用 |
| --- | --- |
| installer.sh | 主入口（--only=detect/collect/install/app/healthcheck/rollback） |
| scripts/precheck.sh | 部署前体检（OS 家族、架构、glibc、磁盘、内存、CPU 指令集） |
| scripts/collect.sh | 一键采集入口（聚合 jdk/mysql/tomcat + 系统依赖） |
| scripts/collect_jdk.sh | 下载/拷贝 JDK 8 tarball 并按家族 × 架构归档 |
| scripts/collect_mysql.sh | 同上，MySQL 8.4 LTS 二进制 tarball + 依赖 glibc 探测（硬性要求 8.4.x） |
| scripts/collect_tomcat.sh | 同上，Tomcat 9 tarball（硬性要求 9 系列） |
| scripts/collect_deb_deps.sh | deb 系镜像机真实采集依赖（apt print-uris 递归下载 libaio/libnuma/ncurses 等） |
| scripts/collect_rpm_deps.sh | rpm 系镜像机真实采集依赖（dnf download --resolve / repotrack） |
| scripts/install_jdk.sh | 安装 JDK 8 + update-alternatives --slave javac/jar（java.security 增量注入，不覆盖 Provider 列表） |
| scripts/install_mysql.sh | 初始化 datadir / 写 my.cnf / 账号初始化（旧版 MariaDB 数据目录自动搬走重建；8.0+ 数据目录保留复用） |
| scripts/install_tomcat.sh | 展开 tarball / 写 server.xml / setenv.sh / 优雅停机脚本 / context.xml 线程回收注入 |
| scripts/systemd_register.sh | 通用 systemctl daemon-reload + enable + start |
| scripts/deploy_app.sh | 自动部署应用：app/sql/*.sql 导入 nkw 库（utf8mb3_general_ci）+ app/war/*.war 解压到 webapps/ROOT + 重启 tomcat（--skip-app 可跳过） |
| scripts/selinux_relax.sh | SELinux 自定义端口放行（仅 semanage 必要时启用） |
| scripts/firewall.sh | 永久关闭防火墙（firewalld/ufw/iptables/nftables 自适应；--skip-firewall 可跳过） |
| scripts/healthcheck.sh | 部署后体检（进程 / 端口 / 登录 / 性能） |
| scripts/rollback.sh | 按 MANIFEST 回滚（删除文件 + 关停服务） |
| scripts/detect_kylin_uos.sh | 麒麟 / 统信专项探测（/etc/.kyinfo + /usr/lib/os-version） |
| scripts/cleanup_old.sh | 卸载/清理系统自带 JDK（含 1.8）/MariaDB/MySQL；识别本工具自管服务支持幂等重装 |
| scripts/write_manifest.sh | 写 MANIFEST.tsv（部署清单，回滚用） |
| scripts/license_collect.sh | 自动收集 deb 包 LICENSE 文本（合规用） |
| scripts/lib.sh | 公共函数（颜色、日志、det_get/det_set、auto_detect_*） |

---

## 退出码

参考 PRD §4.2 NF06：

| 退出码 | 含义 |
| --- | --- |
| 0 | 成功 |
| 1 | 用户错误（参数/权限） |
| 2 | 系统错误（探测/写文件失败） |
| 3 | 依赖缺失 |
| 4 | SELinux/AppArmor 策略调整失败 |
| 5 | 网络错误 |
| 6 | 卸载/清理冲突 |
| 7 | 健康检查失败 |

---

## 文档索引

- docs/PRD.md — 产品需求
- docs/PLAN.md — 实施计划（6 个阶段）
- docs/INSTALL.md — 安装 / 采集 / 部署三步走
- docs/FAQ.md — 常见问题（含 Q0 工作流总览）
- docs/COMPATIBILITY.md — 兼容矩阵（含 §8.2 Kylin/UOS 专项）
- docs/COLLECT_PLANNING.md — 镜像机选型 / 离线包结构
- docs/operations.md — 运维 / 升级 / 备份 / 监控
- docs/rollback.md — 回滚手册
- docs/VALIDATION.md — 交付前 family×arch 矩阵验证手册（必读）

---

## 许可证

本项目脚本 / 文档：MIT（见 LICENSE）。

LICENSES/deb-line/ 目录下的文本是采集到的离线依赖包的原始许可证，
作为合规证据保留，不代表本项目采用这些许可证。