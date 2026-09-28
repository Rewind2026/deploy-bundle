# PRD - 国产化 Linux 离线中间件一键交付工具

> **Status:** Draft v1.0
> **Date:** 2026-09-28

## 1. Vision

为客户提供一份"开箱即用、完全离线、跨国产化 Linux 主流发行版"的中间件交付包，
使现场实施人员无需在客户服务器上编写或调试任何命令，即可在 30 分钟内完成
MySQL 8 + Tomcat 9 + JDK 8 的标准化部署。

## 2. Problem Statement

| 痛点 | 现状 |
|------|------|
| 系统版本/架构碎片化 | 银河麒麟 V10/V11、统信 UOS 1050/1070、openEuler 20.03/22.03/24.03、龙蜥 Anolis；x86_64 / aarch64 / loongarch64 多架构并存 |
| 完全离线 | 客户内网无外网，无法 dnf install / apt install |
| 包管理不一致 | RPM 系 vs Deb 系 |
| 已有组件干扰 | 客户机器常自带 MariaDB / JDK 11/17 / 旧版 Tomcat，需要先卸载再装 |
| 安全策略各异 | SELinux enforcing / AppArmor / firewalld 状态未知且不能全局关闭 |
| 不能装额外工具 | 客户拒绝装 ansible / dnf-plugins / EPEL |
| 等保合规约束 | 必须纯 tar 包、不许动系统 RPM DB、必须保留 LICENSE |
| 版本一致性 | "版本必须一致，否则运行的项目不兼容" |

## 3. Goals

- **G1 一键部署**：`sudo bash installer.sh --auto`
- **G2 全离线**：零外网请求
- **G3 跨发行版**：覆盖 5+ 系统族
- **G4 跨架构**：x86_64 + aarch64
- **G5 安全部署**：SELinux/AppArmor/firewalld 最小放宽
- **G6 兼容性强**：JDK 8u481 / Tomcat 9 / MySQL 8 全栈兼容
- **G7 幂等可回滚**
- **G8 健康检查**：端口/进程/select 1/Tomcat 200

## 4. Requirements

### 4.1 Functional (P0)

| ID | 描述 |
|----|------|
| F01 | 自动探测 OS 家族 + 架构 + glibc |
| F02 | 检测已装 JDK，决定卸载策略 |
| F03 | 检测已装 MySQL/MariaDB，安全清理 |
| F04 | 检测已装 Tomcat，停服务后删除 |
| F05 | 按架构/glibc 选择 tarball |
| F06 | 创建 mysql 用户、初始化 datadir |
| F07 | 写 systemd unit 并 enable |
| F08 | my.cnf 双认证 + skip-name-resolve + +08:00 时区 |
| F09 | SELinux 仅 permissive mysqld_t / tomcat_t |
| F10 | AppArmor 检测并 disable mysqld profile |
| F11 | firewalld/iptables/ufw 自适应端口放行 |
| F12 | --dry-run 模式 |
| F13 | --auto 模式 |
| F14 | 健康检查 |
| F15 | 部署报告 /var/log/installer_report_*.txt |
| F16 | rollback.sh |
| F17 | collect.sh 在 build 机上拉取 |
| F18 | Ansible 顶层 deploy.yml |
| F19 | JDK 8u321+ 3DES/SHA-1 兼容补丁 |
| F20 | Log4Shell 检测警告 |

### 4.2 Non-Functional

| ID | 描述 |
|----|------|
| NF01 | 交付包 ≤ 800 MB |
| NF02 | installer.sh ≤ 50 KB，零外部依赖 |
| NF03 | GPL/Apache 2.0 LICENSE + NOTICE |
| NF04 | 日志到 /var/log/installer_*.log |
| NF05 | sudo 提权 |
| NF06 | 退出码 0=成功 / 1=用户错误 / 2=系统错误 / 3=依赖缺失 / 4=SELinux / 5=网络 |
| NF07 | 交互式确认 |
| NF08 | 多语言 zh-CN / en-US |

## 5. Out of Scope

- 容器化（docker/podman）
- PXE / kickstart 装机
- 高可用 / 主备集群
- 数据库迁移
- 监控 / 告警
- 国产中间件替代

## 6. Stakeholders

| 角色 | 关注点 |
|------|------|
| 项目实施团队 | 一键交付、跨版本兼容 |
| 客户运维 | 不污染系统、可回滚 |
| 客户法务 | GPL 合规 |
| 等保审计 | 日志完整性 |