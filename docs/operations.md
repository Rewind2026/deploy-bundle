id: /root/.trae-cn-server/bin/stable-d654d294a690adb43b5bb35d5b37adf9f292cee0-debian10/modules/ai-agent/libselinux.so.1: no version information available (required by id)
# 运维手册

部署完成后的日常运维操作。

## 1. 服务管理

### 1.1 systemd 单元

| 服务 | 单元名 | 启动命令 |
|------|--------|---------|
| MySQL | `mysqld.service` | `systemctl {start\|stop\|restart\|status} mysqld` |
| Tomcat | `tomcat.service` | `systemctl {start\|stop\|restart\|status} tomcat` |

启用开机自启:
```bash
sudo systemctl enable mysqld tomcat
```

### 1.2 前台启动 (debug 用)

MySQL:
```bash
sudo -u mysql /opt/mysql/bin/mysqld --defaults-file=/etc/my.cnf --console
```

Tomcat:
```bash
sudo -u tomcat /opt/tomcat/bin/catalina.sh run
```

## 2. MySQL 运维

### 2.1 登录

```bash
cat /var/lib/mysql/.root_password
```

格式:
```
root@localhost (caching_sha2): <密码>
root@% (caching_sha2, 远程): <密码>
admin@localhost (mysql_native_password): <密码>
admin@127.0.0.1 (mysql_native_password): <密码>
admin@% (mysql_native_password, 远程): <密码>
```

密码默认为交付约定固定值 **`ywj02402570687`**（`installer.sh --mysql-password=PW` 可在部署时覆盖），
root/admin 同密码；远程访问已默认开启（bind-address=0.0.0.0，root@% 为 caching_sha2_password，
admin@% 为 mysql_native_password 兼容老客户端）。
交付后建议尽快改为各机器独立密码（见 2.2）。

### 2.2 改密码

```sql
ALTER USER 'root'@'localhost' IDENTIFIED BY 'NewStrongPass123!';
ALTER USER 'root'@'%' IDENTIFIED BY 'NewStrongPass123!';
ALTER USER 'admin'@'localhost' IDENTIFIED BY 'NewStrongPass456!';
ALTER USER 'admin'@'%' IDENTIFIED BY 'NewStrongPass456!';
FLUSH PRIVILEGES;
```

### 2.3 备份与恢复

逻辑备份:
```bash
/opt/mysql/bin/mysqldump -u admin -p \
    --single-transaction --routines --triggers --events \
    --all-databases | gzip > /backup/mysql_$(date +%Y%m%d).sql.gz
```

恢复:
```bash
gunzip < /backup/mysql_20260101.sql.gz | /opt/mysql/bin/mysql -u admin -p
```

### 2.4 慢查询

开启:
```sql
SET GLOBAL slow_query_log = 'ON';
SET GLOBAL long_query_time = 2;
SET GLOBAL slow_query_log_file = '/var/lib/mysql/slow.log';
```

查看:
```bash
sudo tail -f /var/lib/mysql/slow.log
```

## 3. Tomcat 运维

### 3.1 应用部署（标准方式）

```bash
# 推荐：走 deploy-bundle 应用部署流程（自动建库/导入/解压/重启）
sudo cp your-app.war /opt/deploy-bundle/app/war/
sudo bash /opt/deploy-bundle/installer.sh --only=app
sudo tail -f /opt/tomcat/logs/catalina.out
```

手工方式（不推荐，注意 appBase 在 deb 系是 /var/lib/tomcat/webapps，其余是 /var/lib/tomcats/webapps）：
```bash
sudo systemctl stop tomcat
sudo cp /path/to/ROOT.war /var/lib/tomcats/webapps/
sudo systemctl start tomcat
```

### 3.2 优雅停机说明

`tomcat.service` 的 ExecStop 调用 `/opt/tomcat/bin/tomcat-stop.sh`：
发送 SHUTDOWN 后最多等 60 秒（`TOMCAT_STOP_WAIT` 环境变量可调），超时才强杀。
 catalina.sh 原生 stop 硬编码只等 5 秒，偏重的 Spring 应用停不干净。
context.xml 已注入 `clearReferencesStopThreads/StopTimerThreads`，应用泄漏的
非守护线程（如 mysql-cj abandoned-connection-cleanup）由 Tomcat 停止时回收。
若 restart 仍偶发 60s+，是应用自身未注册 shutdown hook，属应用代码问题。

### 3.3 内存调整

JVM 参数写在 `/opt/tomcat/bin/setenv.sh`（默认 `-Xms1024M -Xmx4096M` + G1GC），直接编辑：
```bash
sudo vi /opt/tomcat/bin/setenv.sh
sudo systemctl restart tomcat
```

### 3.3 JVM Heap Dump

OOM 时自动 dump 到 `/var/log/tomcat_heapdump.hprof` (deploy-bundle 默认配置)。

## 4. JDK 运维

### 4.1 切换 JAVA_HOME

deploy-bundle 写入 `/etc/profile.d/deploy-bundle-jdk.sh`:
```bash
export JAVA_HOME=/opt/jdk
export PATH=$JAVA_HOME/bin:$PATH
```

切换版本前**先扫 JAVA_HOME 引用**:
```bash
bash /opt/deploy-bundle/scripts/precheck.sh
```

看 `JAVA_HOME_REFS` 字段。

### 4.2 升级 JDK 小版本

```bash
sudo cp -a /opt/jdk /opt/jdk.bak
sudo rm -rf /opt/jdk
# 解压新版本到 /opt/jdk
sudo systemctl restart mysqld tomcat
```

## 5. 安全审计

### 5.1 SELinux 拒绝

```bash
sudo ausearch -m avc -ts recent | grep -E 'mysqld|tomcat'
```

如发现新拒绝，把相应域加入 permissive:
```bash
sudo semanage permissive -a <domain>t
```

### 5.2 防火墙状态

```bash
sudo firewall-cmd --list-all    # firewalld
sudo ufw status                # ufw
sudo iptables -L -n -v          # iptables
```

## 6. 故障排查速查表

| 现象 | 排查命令 |
|------|---------|
| MySQL 启动失败 | `sudo journalctl -u mysqld -n 50` |
| Tomcat 启动阻塞 | `sudo journalctl -u tomcat -n 50` 看熵源 |
| Tomcat HTTP 502 | 检查 MySQL 是否通; `curl -v http://localhost:8080/` |
| MySQL 端口未监听 | `sudo ss -ltnp | grep 3306` |
| Tomcat 端口未监听 | `sudo ss -ltnp | grep 8080` |
| SELinux 拒绝 | `sudo ausearch -m avc -ts recent` |
| AppArmor 拒绝 | `sudo dmesg | grep -i audit` |
| 磁盘满 | `df -h /opt /var` |
| Java OOM | `ls /var/log/tomcat_heapdump.hprof` |

## 7. 健康检查

随时手动跑:
```bash
sudo bash /opt/deploy-bundle/scripts/healthcheck.sh
```

或经 installer:
```bash
sudo bash /opt/deploy-bundle/installer.sh --only=healthcheck
```

报告位置: `/var/log/installer_health_<host>_<date>.txt`