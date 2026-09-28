# Plan - 国产化 Linux 离线中间件交付工具 实施计划

> **Date:** 2026-09-28

## 1. Goal

按 PRD G1-G8 分 6 阶段交付。第一阶段完成后即可 dogfood，第二阶段完成后即可交付试点。

## 2. Phases

### 阶段 0 - 调研与选型 ✅
- 调研国产 OS 覆盖与包管理差异
- 调研 MySQL 8 + Tomcat 9 + JDK 1.8 兼容性细节
- 调研工具形态对比
- 调研 GPL/Apache 2.0 合规要求

### 阶段 1 - 交付包骨架与基础设施 ✅
- T1.1 设计 deliverable 目录结构
- T1.2 编写 installer.sh 主入口
- T1.3 编写 precheck.sh
- T1.4 编写 rollback.sh
- T1.5 写 configs/ 全部模板

### 阶段 2 - 各子系统脚本 ✅
- T2.1 01_detect_os.sh
- T2.2 02_cleanup_old.sh
- T2.3 03_install_jdk.sh
- T2.4 04_install_mysql.sh
- T2.5 05_install_tomcat.sh
- T2.6 06_selinux_relax.sh
- T2.7 07_firewall.sh
- T2.8 08_systemd.sh
- T2.9 99_healthcheck.sh

### 阶段 3 - 依赖收集与打包 ✅
- T3.1 collect.sh
- T3.2 RPM 族 repotrack + createrepo_c
- T3.3 Deb 族 apt-get download + dpkg-scanpackages
- T3.4 packages/ 目录
- T3.5 LICENSES/ 目录

### 阶段 4 - Ansible 顶层 + 文档 ✅
- T4.1 ansible/deploy.yml
- T4.2 ansible/inventory.example
- T4.3 docs/INSTALL.md
- T4.4 docs/COMPATIBILITY.md
- T4.5 docs/rollback.md

### 阶段 5 - 内部 dogfood
- T5.1 CentOS 8 / openEuler 22.03
- T5.2 Kylin V10 SP3
- T5.3 UOS 1050
- T5.4 制造冲突场景
- T5.5 SELinux enforcing + AppArmor + firewalld 全开
- T5.6 幂等性 3 次

### 阶段 6 - 客户试点与版本化
- T6.1 客户试点 dry-run
- T6.2 客户运维跟随
- T6.3 沉淀 FAQ v1
- T6.4 多机部署
- T6.5 交付包版本化
- T6.6 CVE 响应流程

## 3. Acceptance Criteria

### 3.1 功能
- 单台部署 ≤ 30 分钟
- 首次部署成功率 ≥ 95%
- 重复执行幂等性 100%
- 覆盖国产 OS ≥ 6
- 跨架构 x86_64 + aarch64
- 回滚 ≤ 5 分钟

### 3.2 质量
- shellcheck -S warning 通过
- repoclosure + ldd 零 not found
- LICENSES/ 完整
- 日志审计完整

### 3.3 安全
- SELinux 全局仍 enforcing
- 仅 mysqld_t / tomcat_t permissive
- 仅 3306/8080 端口
- 保留 mariadb-libs
- 临时密码 600 权限

## 4. Dependencies

### 4.1 技术
- bash ≥ 4.0
- tar / xz / gzip
- rpm / dpkg
- semanage
- aa-disable
- firewall-cmd
- systemctl
- curl

### 4.2 业务
- 客户提供 target-os/m 信息
- 客户法务审核 GPL
- 客户运维协助 sudo
- MySQL 商业 License（金融客户）

## 5. Risk Register

| 风险 | 等级 | 缓解 |
|------|------|------|
| CPU 指令缺失 | 中 | precheck 告警 |
| mariadb-libs 依赖 | 高 | dnf swap |
| SELinux 自定义模块被驳回 | 中 | 仅 permissive 域 |
| caching_sha2 客户端不兼容 | 中 | admin 备用账号 |
| Tomcat 9 EOL 2027-03-31 | 中 | v2 迁移到 Tomcat 10 |
| GPL 合规拒绝 | 低 | U 盘随包附 |

## 6. v2 Roadmap

- v2.0: aarch64 深度适配 + loongarch64
- v2.1: MySQL 8.4 LTS
- v2.2: Tomcat 10
- v2.3: Ansible AWX 集成
- v2.4: 国产中间件替换路径