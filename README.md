# deploy-bundle

> 离线部署 MySQL 8 + Tomcat 9 + JDK 1.8 到国产化 Linux（银河麒麟 Kylin V10/V11、统信 UOS 1050/1070、openEuler 20.03/22.03/24.03、龙蜥 Anolis OS 8/23 等）的自包含脚本套件。
>
> 支持架构：x86_64 / aarch64 / loongarch64（loongarch 为预留）。

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
sudo bash installer.sh --only=collect --target-family=openeuler-line --target-arch=x86_64

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
| loongarch | Loongnix / Kylin V10 loongarch | 17 | rpm（预留） |

麒麟 / 统信专项适配见 scripts/detect_kylin_uos.sh + docs/COMPATIBILITY.md §8.2。

---

## 子脚本速查

| 脚本 | 作用 |
| --- | --- |
| installer.sh | 主入口（--only=detect/collect/install/healthcheck/rollback） |
| scripts/precheck.sh | 部署前体检（OS 家族、架构、glibc、磁盘、内存、CPU 指令集） |
| scripts/collect.sh | 一键采集入口（聚合下面三个 collect_*） |
| scripts/collect_jdk.sh | 下载/拷贝 JDK 8 tarball 并按家族 × 架构归档 |
| scripts/collect_mysql.sh | 同上，MySQL 8 二进制 tarball + 依赖 glibc 探测 |
| scripts/collect_tomcat.sh | 同上，Tomcat 9 tarball |
| scripts/collect_deb_deps.sh | 客户机 .deb 依赖白名单 + dpkg -i |
| scripts/collect_rpm_deps.sh | 客户机 .rpm 依赖白名单 + rpm -ivh |
| scripts/install_jdk.sh | 安装 JDK 8 + update-alternatives --slave javac/jar |
| scripts/install_mysql.sh | 初始化 datadir / 写 my.cnf / 注册 systemd unit |
| scripts/install_tomcat.sh | 展开 tarball / 写 server.xml / 注册 systemd unit |
| scripts/systemd_register.sh | 通用 systemctl daemon-reload + enable + start |
| scripts/selinux_relax.sh | SELinux 自定义端口放行（仅 semanage 必要时启用） |
| scripts/firewall.sh | firewalld / nftables 端口放行（按家族） |
| scripts/healthcheck.sh | 部署后体检（进程 / 端口 / 登录 / 性能） |
| scripts/rollback.sh | 按 MANIFEST 回滚（删除文件 + 关停服务） |
| scripts/detect_kylin_uos.sh | 麒麟 / 统信专项探测（/etc/.kyinfo + /usr/lib/os-version） |
| scripts/cleanup_old.sh | 卸载/清理已部署版本（含残留进程清理） |
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

---

## 许可证

本项目脚本 / 文档：MIT（见 LICENSE）。

LICENSES/deb-line/ 目录下的文本是采集到的离线依赖包的原始许可证，
作为合规证据保留，不代表本项目采用这些许可证。