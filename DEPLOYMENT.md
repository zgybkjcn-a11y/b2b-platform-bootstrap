# Ubuntu SaaS Docker 部署

> S1 升级补充（未发布）：[180](180-Growth-Insights-S1-Data-Trust-2026-09-15.md) 定义 026 migration、旧行组合外键预检、API/Worker/dispatcher 同步升级、统一增长根目录、util-linux/flock、v2 备份及回退限制。隔离演练通过不授权在现有环境执行 migration 或部署。

适用于 Ubuntu 22.04/24.04 amd64 云服务器。生产源码和 GHCR 镜像保持私有；公开 bootstrap 仓库仅发布安装器、Compose、Caddy 模板与本指南。

## 环境对应关系

- **本机开发测试**：`/home/deniskorfei/projects/b2b-marketing-intelligence-platform-saas` 的 Docker Compose，Web/API 端口为 `31002/31003`。这里用于改代码、跑测试和验收，不是生产入口。
- **GitHub SaaS 多租户仓库**：[`zgybkjcn-a11y/b2b-marketing-intelligence-platform`](https://github.com/zgybkjcn-a11y/b2b-marketing-intelligence-platform)，主要分支为 `feat/multi-tenant-saas`。本机验证通过后提交并推送，再通过 release tag 生成 GHCR 镜像。
- **局域网服务器 SaaS 多租户生产环境**：`192.168.10.110`，对外入口为 `app.yibohose.com`。服务器不从本机工作树运行代码，只通过 bootstrap 使用固定 GHCR 镜像；升级统一执行 `sudo b2b-platform update <tag>`。

关系链固定为：**本机开发测试 → GitHub 仓库 → tag/GHCR 镜像 → 局域网服务器生产**。生产当前版本以公开 bootstrap `stable.json`、容器 digest/commit 和 `sudo b2b-platform status` 为准。`v0.2.0` 带迁移 `026`，之后 `v0.2.1`–`v0.2.11` 为无新增 schema 的增长分析、综合分析与 UI 修复；开发分支可以领先，但未经发布、备份、迁移和健康检查验收的版本不得直接进入生产。

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

## 出网代理与浏览器审计

平台的 PSI、AI、Exa 和普通抓取可继续使用 `.env` 中的 `HTTP_PROXY` / `HTTPS_PROXY`。P3 浏览器审计不直接使用这两个变量：它会连接内部 `browser-audit-egress` 服务。该服务在建立 CONNECT 隧道时解析并校验全部 DNS 答案，拒绝私网、保留、链路本地和云元数据地址，然后把选定的公网 IP 固定传给上游代理，避免上游再次按域名解析造成 DNS rebinding。

安装器和升级器会自动生成 `BROWSER_AUDIT_EGRESS_TOKEN`。`browser-audit-egress` 是 P3 专用旁路服务，不作为 API 硬启动依赖；`b2b-platform doctor` 会检查它是否 healthy，缺失时 P3 保持 fail closed。上游代理必须支持 `CONNECT <public-ip>:<url-port>`；若不支持，P3 会保存 failed 证据，不得改成域名 CONNECT、Chrome 直连或删除 SSRF 检查。详见 [`docs/174`](174-Browser-Audit-Trusted-Egress-Proxy-Implementation-2026-09-13.md)。

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
sudo b2b-platform update v0.1.3
sudo b2b-platform rollback
```

`update` 会先从公开 bootstrap 下载并校验控制文件，保留 `.env` 和当前 IP/domain 模式，再按 `stable.json` 或指定版本执行升级。升级顺序固定为配置检查、创建并验证加密备份、拉取固定镜像、固定并启动保留期兼容的备份服务、幂等 migration、切换服务、健康检查。失败恢复上一应用镜像和控制文件；已固定的备份及清理服务定义和镜像必须保留，数据库不会自动降级。migration 必须 expand-first；只有发行说明的 `rollbackCompatibleFrom` 数组明确包含当前版本时才记录 rollback 目标，正文提到版本不算兼容声明。

首次从 v0.2.22 等旧控制文件进入 Agent 附件版本时，必须先更新为当前、已校验的 `update.sh`。旧升级器会在失败时恢复不支持附件保留期的 Compose；新应用升级入口会在任何备份/迁移前拒绝它。下载当前公开 bootstrap 的 `update.sh` 和 `SHA256SUMS` 到独立目录，执行 `sha256sum -c --ignore-missing SHA256SUMS`，确认 `update.sh: OK` 后，保存旧入口及其SHA，再用`sudo install -m0755 ./update.sh /opt/b2b-platform/update.sh`安装这个正式控制文件，继续`sudo b2b-platform update v0.2.23`。也可直接运行已校验的`sudo bash ./update.sh --version v0.2.23`。之后照常使用`sudo b2b-platform update <version>`。不要手动设置内部 `B2B_RETENTION_UPDATE_PROTOCOL` 绕过这个保护，也不要直接调用旧 `upgrade`。

镜像 tag 不是运行取证。安装/升级会在 pull 后读取 API 镜像的真实 `RepoDigest` 和 OCI `org.opencontainers.image.revision`，写入受保护的 `.env` 并传给 API/worker；缺少合法 digest 或 40 位 commit 时停止启动。升级失败和显式 rollback 会连同 `APP_VERSION` 一起恢复或重取 `IMAGE_DIGEST`、`REPOSITORY_COMMIT`。发布端 `stable.json` 同时记录 API/Web digest；部署检查中缺任一侧证据只能显示 `unverifiable`，不得判为 matched。完整取证和表单回执密钥操作见 [`docs/162`](162-Provenance-and-Form-Receipt-Operations-2026-09-10.md)。

备份存放在 Docker `backup-data` volume。定期从“系统设置 > 数据管理”下载加密归档到异地存储，并单独保管 `BACKUP_ENCRYPTION_KEY` 与 `TENANT_SETTINGS_ENCRYPTION_KEYS`。每季度在隔离环境做恢复演练。

Agent 附件（迁移 036 起）：`agent_attachments` 元数据及线程引用永久保存；原文件、解析文本与 vision 图片只在 `agent_attachment_bodies` 保留 3 天。下载/生成在到期时立即停止读取，`attachment-cleanup` 服务每 5 分钟删除到期内容；健康检查检查最近成功清理时间。设置 `AGENT_ATTACHMENT_CLEANUP_INTERVAL_MS` 可调整扫描间隔（30 秒至 1 小时），不改变文件保留期限。

长期加密备份**包含附件元数据，不包含临时文件表及私有预览正文表的数据**，避免 30 天备份延长正文保留期。恢复后仍能追溯文件名、哈希、上传人和每轮引用；尚未到期的文件也须重新上传，私有预览需要重新生成。恢复完成后、重新开放服务前运行 `docker compose run --rm attachment-cleanup node apps/api/dist/agentAttachmentCleanup.js --once`，将缺失文件标为 `missing`，并确认清理服务健康。`AGENT_BACKUP_IMAGE` 与 `AGENT_ATTACHMENT_CLEANUP_IMAGE` 固定到具备相应能力的 API RepoDigest；首次安装、正常升级、显式回退及失败回退均保留二者。恢复旧控制文件时会将本次已校验的这两个服务定义带回旧 Compose，其他服务沿用旧配置；不能仅保留 `.env` 中旧 Compose 不识别的键。`agent-followup` 跟随应用版本，回退到没有该入口的版本时停止，持久任务保留。具体镜像 pin 与回退证据在当次发布记录维护。

Agent 批次（迁移 037，开发中、尚未发布）：新增多目标 URL、关联修订来源和首次领取时固定的版本/依赖证据；旧单目标请求保留默认值，旧单动作领取响应不新增批次字段。先升级 SaaS API，再安装新 runner；批次生成/UI 尚未开放，完整发布门禁见 220。回退前停止 runner 并核对所有执行中/未知项，批次在途记录不可交给不支持批次的旧 API/runner。保留 runner 私有 `executions/`、`preflight/` 和 `outbox/`：写前渲染证据用于选择性恢复，不能通过删除台账或换幂等键重写。扩展迁移不执行降级删列；正式升级/回退验证尚待发布阶段。

Agent 执行保护（A6，尚未发布）：所有 API 实例须使用同一个 `REDIS_URL`；生产/开发未配置或暂不可用时，新开始和会话写操作返回 503，不退回本机计数。按组织/站点/环境共用每分钟 6 次新开始额度；生产同时最多一条执行，WordPress 的执行中/结果未知与 manual 的执行中/已回报待审核共用该位置。回查、机器回执和存储层重复人工开始不消耗新开始额度。会话生成另限每用户每分钟 6 次、每组织 12 次；其他会话写入每用户 60 次、每组织 240 次，人工回报/审核使用独立计数。用户计数绑定组织与用户 ID，切换会话不重置。429 携带 `Retry-After`，BFF 保留该响应头；AI 日配额复用组织共享服务配置和 PostgreSQL 计量，耗尽不自动重试。限流计数在 Redis，执行占位在 PostgreSQL，不能通过重启 API 释放未知或待审核动作。发布时统一切换所有 API 实例；旧 API 不具备人工共用占位保护，存在这类在途动作时先停止开始入口再按发布回退方案处理。

`TENANT_SETTINGS_ENCRYPTION_KEYS` 使用 `keyId:base64`（每个 key 解码后必须为 32 字节），`TENANT_SETTINGS_ACTIVE_KEY_ID` 指向新写入密钥；轮换时保留旧 key 直到所有历史记录完成迁移。`DATA_BACKEND=json` 的本地兼容模式在未配置密钥时只会在固定数据目录生成一次 `0600` 的 `.tenant-settings-key` 并跨重启复用；`NODE_ENV=production` 缺少显式密钥会直接启动失败。无法解密的历史连接只标记为 `reauthorization_required`，不会输出或猜测迁移任何凭证。

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
- 若升级出现 `web is unhealthy` 或 Caddy 依赖 Web 启动失败，先检查 `docker compose logs --tail=200 web` 以及 `docker inspect <web-container> --format '{{json .State.Health.Log}}'`。公开 `/health` 只代表 API，不代表 Web 页面可用；更新器会等待 Web healthcheck 通过后才报告升级成功，并在失败时恢复应用版本、控制文件和 `.env`。

本 SaaS Docker 域名模式使用 80/443；IP 模式默认使用 8080。两者均与本机开发版 `31002/31003` 以及稳定单机版 `31000/31001` 完全独立，不迁移后两者的数据。


## Agent执行后复测（047，未部署）

迁移047及`agent-followup`见[229](229-Agent-Loop-Followups-2026-10-08.md)。发布须同时部署新worker，核对心跳、实际到期调度与RLS；只读挂载增长数据，不配网站写凭据或AI密钥。旧镜像回退会停止该worker，保留PG任务；恢复新镜像后续接原固定窗口，不重建或清空任务。实际部署/备份/恢复演练尚待新会话完成，当前不把Compose检查算上线证据。
