# Ubuntu SaaS Docker 部署

适用于 Ubuntu 22.04/24.04 amd64 云服务器。生产源码和 GHCR 镜像保持私有；公开 bootstrap 仓库仅发布安装器、Compose、Caddy 模板与本指南。

## 10 分钟安装

准备至少 2 GB 内存、10 GB 可用磁盘。域名模式需开放 TCP 80/443；临时 IP 模式只需开放安装时选择的高位 TCP 端口（默认 8080）。安装器不会修改路由器、SSH 或 UFW。

```bash
curl -fsSL https://raw.githubusercontent.com/zgybkjcn-a11y/b2b-platform-bootstrap/main/install.sh | sudo bash
```

安装固定版本：

```bash
curl -fsSL https://raw.githubusercontent.com/zgybkjcn-a11y/b2b-platform-bootstrap/main/install.sh | sudo bash -s -- --version v1.2.3
```

在 GitHub `Settings > Developer settings > Personal access tokens` 创建只含 `read:packages` 的 token。安装时通过 stdin 登录 GHCR，token 不写入 `/opt/b2b-platform/.env`。配置文件和首次管理员凭据权限均为 `0600`；首次登录必须改密。

## 域名与 IP 试用

正式模式先把域名 A 记录指向服务器公网 IP，选择 `domain` 后 Caddy 自动申请证书、跳转 HTTPS 并发送 HSTS。IP 模式使用 `http://公网IP:端口`，默认端口为 8080，不占用 80/443；页面会持续显示未加密警告。该模式仅适合临时、小范围使用，不应传输敏感业务数据，建议在路由器或防火墙限制允许访问的来源 IP。

例如：

```text
http://203.0.113.10:8080
```

家庭电脑还需要真正的公网 IPv4 或可入站 IPv6、路由器端口映射，以及运营商允许对应端口入站。处于 CGNAT 后时，单独修改本项目端口无法从公网访问。

从 IP 切到域名不会修改账号或数据：

```bash
sudo b2b-platform configure domain
```

命令会核对 DNS、启用 Secure Cookie、重建入口并健康检查；既有会话需要重新登录。

## SMTP

```bash
sudo b2b-platform configure smtp
```

常见端口：Microsoft 365、Google Workspace、SendGrid 通常使用 587 + STARTTLS（`SMTP_SECURE=false`）；部分服务使用 465 + TLS（`true`）。配置后到“系统设置 > 部署检查”发送测试邮件。未配置 SMTP 时，密码重置和邮件告警不可用。

## 首次配置

1. 打开安装输出的 URL，用终端只显示一次的临时密码登录并立即改密。
2. 创建首个组织和管理员，添加站点。
3. 在组织服务配置中填写 AI、Exa、PSI；在 Google 数据中填写 GSC/GA4 只读凭据。
4. 在部署检查页确认 HTTPS、SMTP、备份和租户密钥状态。

平台基础设施密码、域名和 SMTP 只通过服务器命令维护；业务服务配置继续在网页按组织维护。

## 日常运维

```bash
sudo b2b-platform status
sudo b2b-platform doctor
sudo b2b-platform logs api
sudo b2b-platform backup
sudo b2b-platform update
sudo b2b-platform update v0.1.1
sudo b2b-platform rollback
```

`update` 会先从公开 bootstrap 下载并校验控制文件，保留 `.env` 和当前 IP/domain 模式，再按 `stable.json` 或指定版本执行升级。升级顺序固定为配置检查、创建并验证加密备份、拉取固定镜像、幂等 migration、切换服务、健康检查。失败自动恢复上一应用镜像和控制文件，数据库不会自动降级。旧服务器也可执行 `curl -fsSL https://raw.githubusercontent.com/zgybkjcn-a11y/b2b-platform-bootstrap/main/update.sh | sudo bash`。migration 必须 expand-first；只有发行说明明确 schema 兼容时才可 rollback。

备份存放在 Docker `backup-data` volume。定期从“系统设置 > 数据管理”下载加密归档到异地存储，并单独保管 `BACKUP_ENCRYPTION_KEY` 与 `TENANT_SETTINGS_ENCRYPTION_KEYS`。每季度在隔离环境做恢复演练。

## 卸载

```bash
sudo b2b-platform uninstall
```

默认只停止服务，保留配置和 volume。永久删除必须显式执行 `uninstall --purge-data`，并再次输入安装名确认；该操作不可恢复。

## 排障

- 证书失败：确认 A 记录已生效、80/443 未被占用，查看 `b2b-platform logs caddy`。
- 镜像 401：重新执行 `docker login ghcr.io`，PAT 需要 `read:packages` 且账号有私有包权限。
- 邮件失败：确认服务商允许 SMTP、端口未被云厂商封禁，并从部署检查页重试。
- 页面 502：运行 `b2b-platform doctor`，再查看 `api`、`web`、`postgres` 日志。
- 升级停止：备份创建或验证失败会阻止升级，先修复备份服务，不要绕过。

本 SaaS Docker 域名模式使用 80/443；IP 模式默认使用 8080。两者均与本机开发版 `31002/31003` 以及稳定单机版 `31000/31001` 完全独立，不迁移后两者的数据。
