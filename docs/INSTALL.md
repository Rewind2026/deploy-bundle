# INSTALL.md - 客户现场离线部署 5 步上手

> 目标读者：客户现场实施人员 / DBA / 运维
> 阅读时间：5 分钟
> 操作时间：≤ 30 分钟
>
> **前提**：你已经拿到了 deploy-bundle 离线包（含 JDK + MySQL + Tomcat + 系统依赖）。
> 如果你手里只有 deploy-bundle 源码，**先看** [COLLECT_PLANNING.md](./COLLECT_PLANNING.md)
> 在公司有网机器上把离线包打包好再过来。

---

## 0. 收到交付包后第一步

```bash
# 把 deploy-bundle-v1.0-<family>-<arch>.tar.gz 解压到 /opt
cd /opt
sudo tar xzf /path/to/deploy-bundle-v1.0-rhel8-x86_64.tar.gz
cd deploy-bundle

# 查看版本与产物
ls packages/rhel8-line/x86_64/{jdk,mysql,tomcat,rpms}/
cat VERSION
```

确认目录里有：
- `packages/<FAMILY>/<ARCH>/jdk/` — 至少 1 个 `OpenJDK8U-*.tar.gz`
- `packages/<FAMILY>/<ARCH>/mysql/` — 至少 1 个 `mysql-*.tar.xz`（推荐 glibc2.28 + 2.17 双套）
- `packages/<FAMILY>/<ARCH>/tomcat/` — 至少 1 个 `apache-tomcat-*.tar.gz`
- `packages/<FAMILY>/<ARCH>/rpms/` 或 `debs/` — 系统依赖

如果某个目录为空，说明该组件未打包，**别硬跑 installer**，回退到交付方确认。

---

## 1. 第一次：先做 dry-run 探测（不改系统）

```bash
sudo bash installer.sh --dry-run
```

这会：
- 探测 OS 家族、架构、glibc 版本
- 列出已装 JDK/MySQL/Tomcat
- 扫描 JAVA_HOME 引用（避免误卸其他业务）
- 检查端口 3306 / 8080 是否被占用
- **不修改任何系统配置**

输出位置：`/var/log/installer_detect_<主机名>_<时间>.txt`

---

## 2. 部署：自动模式（推荐）

```bash
sudo bash installer.sh --auto
```

执行流程（按顺序跑 7 个 stage）：
1. **detect** — 环境探测（同 dry-run）
2. **cleanup** — 检查并卸载旧版本 JDK/MySQL/Tomcat（保留 mariadb-libs 防 PG 破坏）
3. **install** — 解包三组件、创建 mysql 用户、初始化数据目录、写 systemd unit
4. **selinux** — 仅放松 `mysqld_t` / `tomcat_t` 域（全局仍 enforcing）
5. **firewall** — 打开 3306 / 8080 端口
6. **systemd_register** — 写 `/etc/systemd/system/{mysqld,tomcat}.service` + enable + start
7. **healthcheck** — 14+ 项端口/进程/select/Tomcat 200 检查

---

## 3. 验证

```bash
# 1. 查看健康检查报告
cat /var/log/installer_health_*.txt

# 2. 端口监听
ss -ltn | grep -E ':(3306|8080)'

# 3. MySQL 测试
mysql -u root -p
# 输入 /var/lib/mysql/.root_password 文件里的密码（mysql:mysql 0600）
mysql> SELECT VERSION();

# 4. Tomcat 测试
curl -I http://localhost:8080/
# 应返回 HTTP/1.1 200 或 404（无 ROOT.war 时正常）
```

---

## 4. 部署业务应用

```bash
# 把 war 包放到 Tomcat appBase（默认 /var/lib/tomcat/webapps；rhel 系 /var/lib/tomcats/webapps）
sudo cp your-app.war /var/lib/tomcat/webapps/
sudo systemctl restart tomcat

# 创建业务数据库
mysql -u root -p
mysql> CREATE DATABASE your_app DEFAULT CHARSET utf8mb4;
mysql> CREATE USER 'appuser'@'localhost' IDENTIFIED WITH mysql_native_password BY 'your_password';
mysql> GRANT ALL ON your_app.* TO 'appuser'@'localhost';
mysql> FLUSH PRIVILEGES;
```

---

## 5. 出问题？回滚

```bash
# 列出所有可回滚点
sudo bash scripts/rollback.sh --list

# 回滚到本次部署前状态（保留 MySQL 数据目录）
sudo bash scripts/rollback.sh --yes

# 彻底清理（包括 MySQL 数据目录，慎用！）
sudo bash scripts/rollback.sh --yes --purge-data
```

---

## 高级用法

### 仅跑某个 stage

```bash
sudo bash installer.sh --only=detect        # 仅探测
sudo bash installer.sh --only=cleanup       # 仅卸载旧版本
sudo bash installer.sh --only=install       # 仅安装
sudo bash installer.sh --only=healthcheck   # 仅健康检查
```

### 指定端口

```bash
sudo bash installer.sh --auto \
    --mysql-port=3307 \
    --tomcat-port=8081
```

### 跳过某个组件

```bash
sudo bash installer.sh --auto --skip-mysql      # 不动 MySQL
sudo bash installer.sh --auto --skip-tomcat     # 不动 Tomcat
sudo bash installer.sh --auto --skip-selinux    # 不调整 SELinux 策略
sudo bash installer.sh --auto --skip-firewall   # 不动防火墙
```

---

## 退出码

| Code | 含义 |
|------|------|
| 0 | 成功 |
| 1 | 用户错误（参数 / 权限） |
| 2 | 系统错误（探测/写文件失败） |
| 3 | 依赖缺失（必要工具未装） |
| 4 | SELinux 错误 |
| 5 | 网络错误（健康检查远端时） |
| 6 | 卸载错误（清理冲突） |
| 7 | 健康检查失败 |

---

## 常见问题

### Q1. 部署后 Tomcat 启动慢 / 卡住

A: 检查 `skip-name-resolve=ON` 是否写入 my.cnf。离线环境无 DNS 会导致 30s+ 启动延迟。

### Q2. Navicat 11 连不上 MySQL 8

A: 默认 root 用 `caching_sha2_password`，Navicat 11 不支持。**用脚本里创建的 admin@localhost
（mysql_native_password）**登录。或者新建业务账号时指定 `WITH mysql_native_password`。

### Q3. JDK 8u321+ 老客户端 SSL 失败

A: 已写入 `configs/java.security` 兼容补丁。客户业务用老 SSL 也能通。

### Q4. 客户机器已有 MariaDB

A: 脚本会扫描并警告，`cleanup_old.sh` 默认保留 `mariadb-libs`（防止破坏其他 RPM），只覆盖 mysql 二进制。

### Q5. SELinux 不让启动 MySQL

A: 脚本会自动 `semanage permissive -a mysqld_t tomcat_t`，仅这两个域，全局仍 enforcing。等保审计合规。

### Q6. /opt 空间不够

A: 数据目录在 `/var/lib/mysql`，与 `/opt` 分开。如 `/var` 也不够，部署前先扩展。

### Q7. Tomcat 默认主页被业务方覆盖

A: server.xml 模板默认 `autoDeploy=false`，但 `unpackWARs=true`。首次启动会解包 ROOT.war，删除 `webapps/ROOT/` 即可关闭默认页。

### Q8. 我手里只有源码（没下好的 tarball），怎么部署？

A: **不能直接部署**。deploy-bundle 设计就是离线包机制。源码只用于在公司有网机器上跑 `collect.sh`
打离线包。详见 [COLLECT_PLANNING.md](./COLLECT_PLANNING.md)。

---

## 获取更多帮助

- 镜像机打包流程：[COLLECT_PLANNING.md](./COLLECT_PLANNING.md)
- 兼容性矩阵：[COMPATIBILITY.md](./COMPATIBILITY.md)
- 回滚手册：[rollback.md](./rollback.md)
- FAQ：[FAQ.md](./FAQ.md)
- 产品需求：[PRD.md](./PRD.md)
- 实施计划：[PLAN.md](./PLAN.md)
- 部署日志：`/var/log/installer_*.log`
- 部署报告：`/var/log/installer_report_*.txt`