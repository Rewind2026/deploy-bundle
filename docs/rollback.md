# 回滚手册

## 1. 何时回滚

- 部署后 MySQL/Tomcat 无法启动
- 部署后客户业务系统报错
- 部署后 SELinux/AppArmor 拒绝服务
- 客户要求恢复原状

## 2. 一键回滚

```bash
sudo bash /opt/deploy-bundle/installer.sh --rollback
```

或更彻底 (含数据):
```bash
sudo bash /opt/deploy-bundle/installer.sh --rollback --purge-data
```

## 3. 回滚原理

`scripts/rollback.sh` 的步骤:

1. 停掉 mysqld / tomcat systemd 服务
2. 移除 systemd 单元 (`/etc/systemd/system/mysqld.service` 等)
3. 移除安装目录 (`/opt/jdk`, `/opt/mysql`, `/opt/tomcat`)
4. 恢复原始配置 (my.cnf, server.xml) — 从 `/opt/deploy-bundle-backups/`
5. SELinux 移除自定义 permissive 模块
6. 防火墙移除本工具添加的端口

**默认保留** MySQL 数据目录 `/var/lib/mysql` (除非 `--purge-data`)。

## 4. 备份位置

所有变更前自动备份到:
```
/opt/deploy-bundle-backups/
└── 20260928_140000/                    # 时间戳
    ├── pre_deploy/                    # 部署前快照
    │   ├── jdk_existing/jdk/
    │   ├── mysql_existing/mysql/
    │   └── tomcat_existing/tomcat/
    ├── cleanup_old/                    # 旧版本清理前
    ├── selinux/                        # SELinux 策略原值
    ├── systemd/                        # systemd 单元原值
    └── firewall/                       # 防火墙规则原值
```

列出所有备份:
```bash
sudo bash /opt/deploy-bundle/scripts/rollback.sh --list
```

## 5. 手工回滚 (特殊情况)

如果 `--rollback` 失败或想部分回滚:

### 5.1 只回滚 JDK

```bash
sudo systemctl stop mysqld tomcat
sudo rm -rf /opt/jdk
sudo cp -a /opt/deploy-bundle-backups/<ts>/pre_deploy/jdk_existing/jdk /opt/jdk
```

### 5.2 只回滚 MySQL

```bash
sudo systemctl stop mysqld
sudo systemctl disable mysqld
sudo rm /etc/systemd/system/mysqld.service
sudo systemctl daemon-reload
sudo rm -rf /opt/mysql
sudo cp /etc/my.cnf.orig.* /etc/my.cnf
sudo cp -a /opt/deploy-bundle-backups/<ts>/pre_deploy/mysql_existing/mysql /opt/mysql
# 数据目录默认保留，不删
```

### 5.3 只回滚 Tomcat

```bash
sudo systemctl stop tomcat
sudo systemctl disable tomcat
sudo rm /etc/systemd/system/tomcat.service
sudo systemctl daemon-reload
sudo rm -rf /opt/tomcat /var/lib/tomcat
sudo cp -a /opt/deploy-bundle-backups/<ts>/pre_deploy/tomcat_existing/tomcat /opt/tomcat
```

### 5.4 恢复 SELinux

```bash
sudo semodule -r tomcat_permissive
sudo semanage permissive -d mysqld_t 2>/dev/null || true
sudo semanage permissive -d tomcat_t 2>/dev/null || true
sudo semanage port -d -t mysqld_port_t -p tcp 3307 2>/dev/null || true
sudo semanage port -d -t http_port_t -p tcp 8081 2>/dev/null || true
```

### 5.5 恢复防火墙

firewalld:
```bash
sudo firewall-cmd --permanent --remove-port=3306/tcp
sudo firewall-cmd --permanent --remove-service=mysql
sudo firewall-cmd --reload
```

ufw:
```bash
sudo ufw delete allow 3306/tcp
sudo ufw delete allow 8080/tcp
```

iptables:
```bash
sudo iptables -D INPUT -p tcp --dport 3306 -j ACCEPT
sudo iptables -D INPUT -p tcp --dport 8080 -j ACCEPT
```

## 6. 极端情况: 完全恢复系统

如果备份目录也被破坏，只能重装系统或从快照恢复。建议:

1. **部署前**用虚拟机快照 / 备份工具保存系统
2. **首次部署**在测试机上完成全流程验证
3. **保留 deploy-bundle-backups** 至少 30 天

## 7. 回滚验证

回滚完成后，建议跑一次健康检查确认系统恢复:

```bash
sudo bash /opt/deploy-bundle/installer.sh --only=healthcheck
```