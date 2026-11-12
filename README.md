# Matrix 全栈一键部署

在一台干净的 Ubuntu / Debian 服务器上，用一条命令部署：

- **Synapse** —— Matrix 服务端
- **Element Web** —— 网页客户端
- **LiveKit + lk-jwt** —— 群组语音/视频通话、手机端通话
- **coturn** —— 1:1 通话的 NAT 穿透
- **synapse-admin** —— 图形化管理后台
- **反向代理 + HTTPS** —— 由 1Panel 的 OpenResty 或独立 nginx 承担

> 本文档假设你走 **Cloudflare + 1Panel** 这条路线。
> 不用 1Panel 也能跑（`--panel standalone`），差别见第 3 节末尾。

---

## 快速开始（已在真机验证的 10 步）

> 标记说明：🖱️ 在 1Panel 网页点 ｜ ⌨️ 在面板终端粘命令 ｜ 🤖 脚本自动做 ｜ 👀 系统输出（不用操作）

| # | 动作 | 类型 | 做什么 |
|---|---|---|---|
| 1 | 登录面板 | 🖱️ | 打开面板地址，输入账号密码 |
| 2 | 装 OpenResty | 🖱️ | 应用商店搜 `openresty` → 安装 |
| 3 | 跑部署 | ⌨️ | 面板「终端」里粘一条命令（见 4.1），会依次问域名/前缀/Token/密码 |
| 4 | 建三个站点 | 🖱️ | 网站 → 创建 → 反向代理，填三行表 |
| 5 | 上传占位证书 | ⌨️+🖱️ | `cat` 打印证书 → 粘进「上传证书」 |
| 6 | 开 HTTPS | 🖱️ | 三个站点各选一次占位证书 |
| 7 | 建两个账户 | 🖱️ | 证书 → Acme 账户 / DNS 账户 |
| 8 | 申请正式证书 | ⌨️+🖱️ | `cat` 钩子 → 申请证书（推送目录+钩子） |
| 9 | 补 nginx 片段 | ⌨️ | `bash /opt/matrix/panel-cert/apply-snippets.sh` |
| 10 | 登录网页 | 🖱️ | 打开 `https://<网页域名>`，登录 |

需要你粘的命令一共 5 条（1 条部署 + 2 条打印证书 + 1 条打印钩子 + 1 条写片段）：

```bash
# ③ 部署（把域名、Token、密码换成你自己的）
bash -c "$(curl -sSL https://raw.githubusercontent.com/ostar999/auto-matrix-element-1panel-cf/main/install.sh)" _ \
  --non-interactive --panel 1panel --cert-mode panel \
  --domain example.com --web-host chat \
  --cf-token "你的Token" --admin-user ostar --admin-pass "你的密码"

# ⑤ 打印占位证书（分别打印 .crt 和 .key，复制输出粘进面板）
cat /opt/matrix/panel-cert/placeholder.crt
cat /opt/matrix/panel-cert/placeholder.key

# ⑧ 打印续期钩子（复制输出粘进「申请证书」的脚本框）
cat /opt/matrix/panel-cert/ssl-sync-hook.sh

# ⑨ 写入三个 nginx 片段并重载
bash /opt/matrix/panel-cert/apply-snippets.sh
```

🤖 其余全部自动：建 DNS 记录、生成配置与密钥、起 7 个容器、续期同步、重载 OpenResty。

---

## 目录

- [快速开始（10 步）](#快速开始已在真机验证的-10-步)

- [0. 这些材料分别从哪来](#0-这些材料分别从哪来)
- [1. 服务器准备](#1-服务器准备)
- [2. Cloudflare 准备](#2-cloudflare-准备)
- [3. 1Panel 准备](#3-1panel-准备)
- [4. 跑脚本](#4-跑脚本)
- [5. 部署完成之后](#5-部署完成之后)
- [6. 参数速查](#6-参数速查)
- [7. 常见问题](#7-常见问题)

---

## 0. 这些材料分别从哪来

先把「东西从哪买/从哪拿」说清楚，后面每一节再讲具体怎么配。

| # | 材料 | 从哪来 | 怎么拿 | 费用 |
|---|---|---|---|---|
| 1 | 服务器 | 云厂商（各大 VPS 商家均可） | 下单后邮件里给 IP、root 密码、SSH 端口 | 按配置 |
| 2 | 域名 | 域名商（Cloudflare Registrar / Namesilo / 阿里云…） | 买完在域名商后台能看到 | ~¥50/年 |
| 3 | Cloudflare 账号 | <https://dash.cloudflare.com/sign-up> | 邮箱注册，免费 | 免费 |
| 4 | Cloudflare API Token | Cloudflare 后台 | **第 2.4 节，12 步** | 免费 |
| 5 | 1Panel | 官网一键脚本 | 第 3.1 节，一条命令 | 免费 |
| 6 | OpenResty | 1Panel 应用商店 | 第 3.2 节，点安装 | 免费 |
| 7 | 证书 | **脚本自动申请** | 不用准备，给个邮箱即可 | 免费 |

> 也就是说：你真正要**手动去搞**的只有 4 样——
> 买服务器、买域名、注册 Cloudflare、创建 API Token。
> 剩下的脚本和 1Panel 都能一条命令/点几下搞定。

### 0.1 最短路径清单

```
□ 1. 买服务器，记下 IP / root 密码 / SSH 端口
□ 2. 买域名（或在已有域名商那里）
□ 3. 注册 Cloudflare，把域名 NS 指过去（第 2 节）
□ 4. 创建 API Token，复制 cfut_ 开头那串（第 2.4 节）
□ 5. 云控制台放行 80/443/7881/3478 + UDP 段（第 1.3 节）
□ 6. 装 1Panel + 装 OpenResty（第 3 节）
□ 7. 跑脚本（第 4 节）
□ 8. 回 1Panel 建 3 个站点、传证书、开 HTTPS（第 3.4~3.8 节）
```

---

## 1. 服务器准备

### 1.0 买完服务器先记下这三样

下单成功后，云厂商一般会在邮件 / 控制台「实例详情」里给你：

| 信息 | 长什么样 | 在哪找 |
|---|---|---|
| 公网 IP | `203.0.113.10`（示例） | 实例详情页 |
| root 密码 | 一串随机字符 | 首次开通的邮件，或控制台「重置密码」 |
| SSH 端口 | 大多 `22`，有些商家给非标准端口（如 `2222`） | 实例详情页 / 邮件 |

> 非标准 SSH 端口很常见（省得被扫），登录时要加 `-p`：
> ```bash
> ssh -p 2222 root@203.0.113.10
> ```

### 1.1 最低配置

| 项 | 最低 | 建议 |
|---|---|---|
| 系统 | Ubuntu 20.04+ / Debian 11+ | Ubuntu 24.04 |
| 内存 | 1 GB（脚本会自动加 2 GB swap） | 2 GB |
| 磁盘 | 10 GB | 40 GB+（媒体文件很占） |
| 架构 | x86_64 / aarch64 | — |

### 1.2 登录

```bash
ssh root@你的服务器IP
```

### 1.3 放行端口（**必做**）

在云厂商控制台的「安全组 / 防火墙」里加规则：

| 方向 | 协议 | 端口 | 用途 |
|---|---|---|---|
| 入站 | TCP | 80 | HTTP（证书校验、跳转） |
| 入站 | TCP | 443 | HTTPS |
| 入站 | TCP | 7881 | LiveKit TCP 兜底 |
| 入站 | TCP | 3478 | TURN |
| 入站 | UDP | 3478 | TURN |
| 入站 | UDP | 49160-49200 | TURN 中继 |
| 入站 | UDP | 50000-50100 | LiveKit 媒体 |

> 只做聊天不要通话？那就只要 80 和 443。
>
> 判断端口有没有生效：
> ```bash
> nc -z 你的服务器IP 443   # 从你本机执行
> ```
> 服务器上 `ufw status` 显示放行了、但外面连不上，说明拦在**云厂商那层**。

---

## 2. Cloudflare 准备

这一节全部在浏览器里完成，一共 4 件事：**注册 → 加站点 → 改 NS → 建 Token**。

### 2.1 注册 Cloudflare 账号

1. 打开 <https://dash.cloudflare.com/sign-up>
2. 填邮箱 + 密码 → **Sign up**
3. 去邮箱点验证链接

> 已有账号直接 <https://dash.cloudflare.com> 登录。

### 2.2 把域名添加进来

1. 登录后点右上角 **Add a site**（或首页的 **+ Add a site**）
2. 输入你的域名（**只要主域**，如 `example.com`，不要带 `www`、不要带 `https://`）
3. 选套餐 → **Free** → **Continue**
4. Cloudflare 会自动扫一遍现有 DNS 记录，直接 **Continue**
5. 最后一步会给你**两个 NS 地址**，形如：

   ```
   aria.ns.cloudflare.com
   bob.ns.cloudflare.com
   ```

   **把这两个地址复制下来**，下一步要用。

### 2.3 去域名商改 NS（关键一步）

打开你买域名的网站后台，找到「DNS 服务器 / Nameservers」设置，
把原来的 NS 删掉，换成 Cloudflare 给的那两个。

各家位置不同，常见路径：

| 域名商 | 路径 |
|---|---|
| Cloudflare Registrar | 不用改，本身就是 CF |
| Namesilo | My Account → Domain Manager → 域名 → **Change Nameservers** |
| 阿里云 | 域名控制台 → 域名列表 → **DNS 修改** → 自定义 DNS |
| 腾讯云 | 域名注册 → 我的域名 → **DNS 解析** → 修改 DNS 服务器 |
| GoDaddy | My Products → DNS → **Nameservers** → Change |

改完等生效（10 分钟 ~ 2 小时）。**验证方法**：

```bash
dig NS example.com +short
```

输出里出现 `*.ns.cloudflare.com` 就说明生效了。没生效之前，
Cloudflare 后台该域名会显示 **Pending Nameserver Update**。

> ⚠️ NS 没生效就去申请证书，会报「找不到 zone」。等它变 **Active** 再往下走。

### 2.4 创建 API Token（重点，12 步）

脚本要用这个 Token 干两件事：**自动建 DNS 记录** + **申请证书（DNS-01 校验）**。

**直达链接**：<https://dash.cloudflare.com/profile/api-tokens>

也可以点：右上角头像 → **My Profile** → 左侧 **API Tokens**。

#### 走模板（快，推荐）

1. 页面右上角点 **Create Token**
2. 模板列表里找到 **Edit zone DNS** → 点它右边的 **Use template**
3. **Token name** 填 `matrix-deploy`
4. 往下看 **Permissions**，模板已经填好两行，确认是：

   | 组 | 资源 | 权限 |
   |---|---|---|
   | Zone | DNS | **Edit** |
   | Zone | Zone | **Read** |

   > 如果只有第一行，点 **+ Add more** 补上 `Zone → Zone → Read`。
   > 少了这行，建 DNS 能成功，但**申请证书会失败**。

5. **Zone Resources** 选：

   ```
   Include → Specific zone → example.com
   ```

6. **TTL** 留空（永不过期）；**Client IP Address Filtering** 留空
7. 点 **Continue to summary**
8. 核对一遍，点 **Create Token**
9. 页面显示一串 `cfut_` 开头的字符串 —— **这就是 Token，只显示这一次**

#### 或者走自定义（等价）

1. **Create Token** → 拉到最下面 **Create Custom Token**
2. Token name：`matrix-deploy`
3. **Permissions** 手动加两行：

   ```
   Zone  →  DNS   →  Edit
   Zone  →  Zone  →  Read
   ```

4. Zone Resources：`Include → Specific zone → example.com`
5. **Continue to summary** → **Create Token** → 复制

#### 复制完立刻验证

```bash
curl -s -H "Authorization: Bearer cfut_你复制的那串" \
  "https://api.cloudflare.com/client/v4/user/tokens/verify"
```

返回里 `"status":"active"` 就对了。

再验证能不能读到 zone：

```bash
curl -s -H "Authorization: Bearer cfut_你复制的那串" \
  "https://api.cloudflare.com/client/v4/zones?name=example.com" | head -c 200
```

`"success":true` 且有 `"name":"example.com"` 才说明 Zone:Read 生效。

> ❌ **不要用 Global API Key**（旧版那个 37 位十六进制串）。
> 它的权限是整个账号，泄露等于账号被接管。脚本只认 API Token。

### 2.5 脚本会建哪几条 DNS 记录

跑脚本时会自动创建（已经存在且指向本机的会跳过）：

| 记录 | 指向 | 代理状态 | 为什么 |
|---|---|---|---|
| `chat.example.com` | 服务器 IP | **橙云（已代理）** | 网页走 CF，隐藏源站、加速 |
| `chatapi.example.com` | 服务器 IP | **灰云（仅 DNS）** | 大文件上传不能被 CF 卡 100 MB |
| `chatad.example.com` | 服务器 IP | **橙云（已代理）** | 管理后台走 CF |

三条都是一级子域，一张 `*.example.com` 通配符证书就能全覆盖。

**橙云 vs 灰云在哪改**：Cloudflare → 你的域名 → **DNS** → **Records**，
点那条记录右侧的橙色云朵图标即可切换（橙色=已代理，灰色=仅 DNS）。

> ⚠️ **`chatapi` 必须是灰云**。橙云状态下 Cloudflare 免费版会把
> 请求体限制在 100 MB，「无限上传」就废了。
>
> 想三个都灰云：脚本加 `--no-proxy-web`。

### 2.6 证书模式（默认交给 1Panel）

脚本申请的是 **Let's Encrypt 正式证书**（不是 Cloudflare 的源站证书），所以：

- Cloudflare → SSL/TLS → Overview 设成 **Full (strict)** 是安全的
- 无需在 Cloudflare 里上传任何证书

证书由谁管由 `--cert-mode` 决定：

| 模式 | 谁签发 | 续期 | 首次人工 |
|---|---|---|---|
| `panel`（默认） | 1Panel | 面板定时任务 + 推送目录 + 钩子 | 需在面板点 4 步 |
| `acme` | 脚本里的 acme.sh | acme.sh cron + `renew-hook.sh` | 全自动 |

两种模式都验证过。**不要同时开**，否则会撞 Let's Encrypt 的签发限额。

---

## 3. 1Panel 准备

> 不想用 1Panel？跳到 [3.9](#39-不用-1panel-的话)。

### 3.1 安装 1Panel

1Panel 是开源的服务器面板，官网 <https://1panel.cn>，一键安装脚本来自它的官方 CDN。
在服务器上以 root 执行：

```bash
bash -c "$(curl -sSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh)"
```

安装过程会让你设置：

- 1Panel 端口（默认随机，比如 `23955`）
- 安全入口（一串随机字符）
- 用户名 / 密码

装完执行：

```bash
1pctl user-info
```

把输出的 **面板地址 / 安全入口 / 用户名 / 密码** 记下来。

### 3.2 登录并装 OpenResty

浏览器打开 `http://服务器IP:端口/安全入口` 登录。

左侧 **应用商店** → 搜索 `openresty` → 点 **安装** → 弹窗保持默认
（HTTP 80、HTTPS 443、网站目录 `/opt/1panel/www`）→ **确认**。

等状态变成「已启动」。

> 1Panel 的站点管理依赖它自己的 OpenResty 容器。
> 如果服务器上已经有别的 nginx 占着 80/443，这里会启动失败：
> ```bash
> systemctl disable --now nginx
> ```

### 3.3 1Panel 防火墙（和云安全组是两层，都要放）

左侧 **系统 → 防火墙** → 确认 **ufw 已启用** → 点 **创建**，把第 1.3 节的
7 条规则加进去（或至少 80 / 443）。

> 云安全组是机房那层，1Panel 防火墙是系统这层。**两层都通才行**。

### 3.4 建三个站点

左侧 **网站 → 创建 → 选「反向代理」**，建三个：

| 域名 | 代号 | 代理地址 |
|---|---|---|
| `chat.example.com` | `chat` | `http://127.0.0.1:9180` |
| `chatapi.example.com` | `chatapi` | `http://127.0.0.1:9108` |
| `chatad.example.com` | `chatad` | `http://127.0.0.1:9182` |

> **代理地址要带 `http://`**，端口不能写错：
> 9180 = Element，9108 = Synapse，9182 = 管理后台。
>
> 三个端口都只监听 `127.0.0.1`，只有本机能访问，不会被公网直接打到。

### 3.4b 证书由谁管（默认：1Panel）

脚本默认把证书管理交给 1Panel（`--cert-mode panel`），部署时会生成两样东西：

```
/opt/matrix/panel-cert/placeholder.crt/.key   占位自签证书
/opt/matrix/panel-cert/ssl-sync-hook.sh       续期后同步+reload 的钩子
```

**为什么需要占位证书**：站点要先开启 HTTPS，nginx 配置才会指向
`/www/sites/<代号>/ssl/`。占位证书只是用来"占位"，稍后会被正式证书覆盖。

**面板里的三步**（脚本跑完会打印同样的提示）：

1. 上传占位证书 → 三个站点开启 HTTPS 并选它
2. 申请正式证书：主域名 + 其他域名，DNS 账号，勾**自动续签**
3. 同一次申请里勾选：
   - **推送证书到本地目录** → `/opt/1panel/www/sites/<网页代号>/ssl`
   - **申请证书之后执行脚本** → 粘贴 `ssl-sync-hook.sh` 的内容

点确认后：签发 → 推送覆盖 → 执行脚本 → 三个站点自动生效。之后续期同链路，全自动。

**证书就位后还剩一件事**：补三个 nginx 片段（客户端发现、解除上传限制、LiveKit 信令）。
不用手写，脚本已经生成了执行文件：

```bash
bash /opt/matrix/panel-cert/apply-snippets.sh
```

输出 `✓ 三个片段已写入并重载 OpenResty` 即完成。可以重复执行。

> 想回到「脚本自己用 acme.sh 签」的老方式：加 `--cert-mode acme`。
> 两种方式**不要同时启用**，否则会撞 Let's Encrypt 的签发限额。

### 3.5 上传证书并开启 HTTPS

**先传证书**：左侧 **网站 → 证书 → 上传证书**

| 字段 | 填什么 |
|---|---|
| 名称 | `matrix-chat` |
| 证书内容 | `cat /etc/nginx/ssl/matrix/fullchain.pem` 的全文 |
| 私钥内容 | `cat /etc/nginx/ssl/matrix/privkey.pem` 的全文 |

> 这两个文件是脚本跑完后生成的。先跑脚本、再回来传证书。

**再开 HTTPS**：**网站** → 找到站点 → 点 **配置** → 左侧 **HTTPS** →
打开「启用 HTTPS」开关 → HTTP 选项选「访问 HTTP 自动跳转到 HTTPS」→ **保存**。

三个站点都要做一遍。

### 3.6 管理后台加密码（**必做**）

`synapse-admin` 本身没有登录校验，不挡的话谁都能进。

**网站** → `chatad` 站点 → **配置** → 左侧 **密码访问** → **创建**：

- 用户名：自定义（比如 `ostar`）
- 密码：设置一个

创建完，**把这一页的那个小开关打开**（不开不生效，这里很容易漏）。

### 3.7 给 API 站点补一段配置

> **不想看原理的，直接跑这一条**（站点建好、证书就位之后）：
>
> ```bash
> bash /opt/matrix/panel-cert/apply-snippets.sh
> ```
>
> 它会写完 3.7 + 3.8 要求的全部片段并重载 OpenResty。
> 下面保留手动做法和原理，仅供排查问题时参考。

#### 3.7.1 为什么必须改

1Panel 建站点时，只会填一个上游地址，所以**所有请求都转给 Synapse**：

```
https://chatapi.example.com/任意路径  ──►  127.0.0.1:9108（Synapse）
```

但这台机器上其实跑着**三个**程序，各占一个端口：

| 程序 | 端口 | 负责什么 | 有独立域名吗 |
|---|---|---|---|
| Synapse | 9108 | 登录、消息、文件上传下载 | 有（chatapi） |
| LiveKit | 7880 | 音视频房间的信令（WebSocket） | ❌ 没有 |
| lk-jwt | 8080 | 通话前签发 token | ❌ 没有 |

后两个没有域名，只能借用 `chatapi` 这个域名，靠**路径**区分。

如果不加下面这段配置，Element 发起通话时，请求 `/livekit/jwt/...` 会被当成
Matrix API 的路径发给 Synapse，Synapse 不认识 → **404 → 通话打不开**。

#### 3.7.2 要达成的效果

```
https://chatapi.example.com/livekit/sfu/...   ──►  LiveKit   127.0.0.1:7880
https://chatapi.example.com/livekit/jwt/...   ──►  lk-jwt    127.0.0.1:8080
https://chatapi.example.com/其他所有路径        ──►  Synapse  127.0.0.1:9108
```

#### 3.7.3 操作（3 步）

**第 1 步：找到这个文件**

```
/opt/1panel/www/sites/chatapi/proxy/root.conf
                      └──┬──┘
                    站点「代号」
```

- `chatapi` 是**建站点时填的「代号」**，不是域名。你填 `xyz`，路径就是
  `/opt/1panel/www/sites/xyz/proxy/root.conf`
- 想确认代号：**网站** → 站点那一行的「网站目录」列，或直接 `ls /opt/1panel/www/sites/`

打开方式二选一：

- **1Panel 界面**：左侧 **文件** → 地址栏输入 `/opt/1panel/www/sites/chatapi/proxy`
  → 找到 `root.conf` → 右键 **编辑**
- **SSH**：见下面的第 2 步

**第 2 步：把文件内容整体替换**

把这**整个文件**的内容清空，粘贴下面这段：

```nginx
# ① LiveKit 信令（WebSocket）
location ^~ /livekit/sfu/ {
    proxy_pass http://127.0.0.1:7880/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;
}

# ② lk-jwt 签发通话 token
location ^~ /livekit/jwt/ {
    proxy_pass http://127.0.0.1:8080/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}

# ③ 其余全部给 Synapse
location ^~ / {
    client_max_body_size 0;
    proxy_request_buffering off;
    proxy_pass http://127.0.0.1:9108;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_send_timeout 3600s;
    proxy_read_timeout 600s;
}
```

> 📌 **这段里没有域名，不需要替换任何东西。**
> 域名写在 1Panel 自己生成的 `/opt/1panel/www/conf.d/chatapi.conf`（`server_name` 那行），
> 这里只负责「哪条路径转发到哪个端口」。端口用的就是脚本默认值（7880/8080/9108），
> 除非你改过 `docker-compose.yaml`，否则原样粘贴即可。

用 SSH 一次性写入（把 `chatapi` 换成你的代号）：

```bash
cat > /opt/1panel/www/sites/chatapi/proxy/root.conf <<'EOF'
（把上面那段粘进来）
EOF
```

> 注意 `<<'EOF'` 的引号不能丢：没有引号的话，`$host`、`$http_upgrade`
> 会被 shell 当成变量展开成空字符串，配置就废了。

**第 3 步：让配置生效**

```bash
ct=$(docker ps --format '{{.Names}}' | grep -i openresty | head -1)
docker exec "$ct" openresty -t        # 先检查语法，能看到 successful
docker exec "$ct" openresty -s reload # 再重载
```

#### 3.7.4 这段配置里每一行在做什么

| 配置 | 作用 |
|---|---|
| `location ^~ /livekit/sfu/` | 匹配以这个开头的请求；`^~` 表示优先级高于后面的 `/` |
| `proxy_pass http://127.0.0.1:7880/;` | **结尾的 `/` 是关键**：它会把 `/livekit/sfu` 这段前缀剥掉再转发 |
| `proxy_set_header Upgrade $http_upgrade;`<br>`proxy_set_header Connection "upgrade";` | 允许 WebSocket 长连接（LiveKit 信令就是 WS） |
| `proxy_read_timeout 3600s;` | 通话可能持续很久，超时设大一小时 |
| `proxy_buffering off;` | 信令是实时的，不能攒着再发 |
| `client_max_body_size 0;` | **0 = 不限大小**。nginx 默认只收 1 MB，不改这条传不了大文件 |
| `proxy_request_buffering off;` | 边收边转，不会先把整个文件写到临时目录再转发 |

关于「剥前缀」举个具体例子：

```
Element 请求：wss://chatapi.example.com/livekit/sfu/rtc?access_token=xxx
实际转给：    ws://127.0.0.1:7880/rtc?access_token=xxx
                                    ↑ /livekit/sfu 被去掉了
```

LiveKit 只认 `/rtc`，多一层前缀它会 404。所以 `proxy_pass` 结尾那个斜杠
**不能省**。

#### 3.7.5 验证

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://chatapi.example.com/livekit/jwt/healthz
curl -s -o /dev/null -w '%{http_code}\n' https://chatapi.example.com/_matrix/client/versions
```

两个都返回 `200` 才算对：

| 结果 | 说明 |
|---|---|
| 两个 200 | ✅ 配置正确 |
| 第一个 404 | `/livekit/jwt/` 那段没生效，检查 `proxy_pass` 结尾斜杠 |
| 第一个 502 | lk-jwt 容器没起来，`docker compose ps` 看一下 |
| 两个都 404 | 文件没被 include，检查是不是改错了目录（代号对不对） |

#### 3.7.6 一个必须记住的坑

> ⚠️ 在 1Panel 界面里点这个站点的 **配置 → 反向代理 → 保存**，
> `root.conf` 会被**整个重新生成**，上面这三段配置全部丢失，
> 通话和大文件上传会同时失效。
>
> 一旦在界面里动过反向代理，就要回到 3.7.3 重新粘一遍。

### 3.8 给网页站点加客户端发现

新建一个**新文件**（不要改 `root.conf`，这个文件不会被面板覆盖）：

`/opt/1panel/www/sites/chat/proxy/zz-wellknown.conf`

```nginx
location = /.well-known/matrix/client {
    default_type application/json;
    add_header Access-Control-Allow-Origin "*" always;
    add_header Cache-Control "public, max-age=300";
    return 200 '{"m.homeserver":{"base_url":"https://chatapi.example.com"}}';
}

location = /.well-known/matrix/server {
    default_type application/json;
    add_header Access-Control-Allow-Origin "*" always;
    return 200 '{"m.server":"chatapi.example.com:443"}';
}
```

把代码里出现 `chatapi.example.com` 的**两处**都换成你的 API 域名：

- `"base_url":"https://chatapi.example.com"` —— Element 登录时连的地址
- `"m.server":"chatapi.example.com:443"` —— 联邦委派，lk-jwt 校验身份时读

> 没有这一段，Element 登录会一直转圈，手机端通话也会失败
> （lk-jwt 校验身份时要读 `.well-known/matrix/server`）。

### 3.9 不用 1Panel 的话

加 `--panel standalone`，脚本会自己 `apt install nginx` 并写好站点，
不需要手动配置。

代价：1Panel 的「网站」功能用不了（它需要自己的 OpenResty），
而且以后每次续期都要靠 `systemctl reload nginx`。

---

## 4. 跑脚本

### 4.1 一条命令（推荐）

```bash
bash -c "$(curl -sSL https://raw.githubusercontent.com/ostar999/auto-matrix-element-1panel-cf/main/install.sh)"
```

全交互，会依次问你（**全部回车即用默认**）：

```
==> 基本参数
? 主域名: example.com
? 网页前缀（用户 ID 会用这个）[chat]:
? API 前缀 [chatapi]:
? 管理后台前缀 [chatad]:

==> 可选设置
? 站点名称 / 品牌 [Matrix Chat]:
? 单文件上传上限 [2G]:
? 联邦模式 closed/whitelist/open [closed]:
? 允许任何人注册 [n]:
? 允许游客浏览房间 [n]:
? 默认界面语言 [zh_Hans]:
? 默认主题 light/dark [light]:
? 启用音视频通话 [Y]:

==> 面板
? 检测到 1Panel，网站是否交给它管理? [y]:

==> Cloudflare API Token
? 粘贴 Cloudflare API Token（输入时不显示）: ********
   ← 第一次跑必填；输入时看不见，正常

==> 管理员
? 管理员用户名 [ostar]:
? 管理员密码: ********      ← 输入时看不见，正常
```

> **Token 这一项是必填的**（除非加 `--skip-dns`）。
> 不填会导致建不了 DNS 记录、后面证书也签不出来。

每一项的含义：

| 问题 | 默认 | 说明 |
|---|---|---|
| 站点名称 / 品牌 | `Matrix Chat` | Element 顶部显示的名字 |
| 单文件上传上限 | `2G` | 填 `0` 表示不限；100M/500M/2G/10G 都可以 |
| 联邦模式 | `closed` | `closed` 只本机互通；`whitelist` 指定域名；`open` 加入公共网络 |
| 允许任何人注册 | `n` | 开了容易被扫描器批量注册 |
| 允许游客浏览房间 | `n` | 无账号可看被标记为公开的房间 |
| 默认界面语言 | `zh_Hans` | `en` 等 |
| 默认主题 | `light` | `light` / `dark` |
| 启用音视频通话 | `Y` | 选 `n` 就不装 LiveKit 和 coturn |

### 4.2 带参数（半自动）

```bash
bash -c "$(curl -sSL .../install.sh)" _ \
  --domain example.com \
  --web-host chat \
  --cf-token "cfut_xxxxxxxx" \
  --admin-pass "你的密码" \
  --panel 1panel
```

想自定义这些「可选设置」，追加对应参数即可：

```bash
  --brand "我们公司的聊天" \
  --max-upload 500M \
  --federation whitelist --federation-domains "partner.com" \
  --allow-registration \
  --allow-guests \
  --language en \
  --theme dark
```

### 4.3 先看一眼会生成什么

```bash
bash -c "$(curl -sSL .../install.sh)" _ \
  --dry-run --skip-dns --non-interactive \
  --domain example.com --web-host chat --admin-pass x12345678 \
  --dir /tmp/matrix-test
```

配置渲染到 `/tmp/matrix-test`，不起容器。建议第一次都跑一遍。

### 4.4 或者 clone 下来跑

```bash
git clone https://github.com/ostar999/auto-matrix-element-1panel-cf.git
cd auto-matrix-element-1panel-cf
sudo bash install.sh
```

### 4.5 执行顺序

```
① 环境检查（root / 系统 / 内存 / 磁盘 / 80·443 是否空闲）
② 补 swap（内存 < 2GB 时）
③ 装 Docker
④ 选托管方式（1Panel / 独立 nginx）
⑤ 建 3 条 DNS 记录
⑥ 渲染配置 + 随机生成全部密钥
⑦ 起 7 个容器，等 Synapse 健康
⑧ 签证书（DNS-01）
⑨ 装站点（1Panel 模式到这里会打印剩余步骤）
⑩ 建管理员 + 自检
```

---

## 5. 部署完成之后

| 地址 | 说明 |
|---|---|
| `https://chat.example.com` | Element 网页，用户在这里登录 |
| `https://chatad.example.com` | 管理后台（Basic Auth + Matrix 账号两层） |
| `https://chatapi.example.com` | API，客户端通过 `.well-known` 自动发现，不用手填 |

管理后台登录：

1. 浏览器弹窗：填 **3.6 里创建的密码访问账号**
2. 面板内「服务器地址」填 `https://chatapi.example.com`
3. 用 Matrix 管理员账号登录

### 查看本次安装用的参数

脚本会把所有有效参数写进一个文件：

```bash
cat /opt/matrix/install-manifest.json
```

```json
{
  "version": "1.2.0",
  "installed_at": "2026-11-12T15:30:00+08:00",
  "domain": "example.com",
  "web_host": "chat",
  "api_host": "chatapi",
  "admin_host": "chatad",
  "brand": "Matrix Chat",
  "max_upload_size": "2G",
  "federation": "closed",
  "federation_domains": "",
  "allow_registration": false,
  "allow_guests": false,
  "language": "zh_Hans",
  "theme": "light",
  "panel_mode": "1panel",
  "rtc": true,
  "admin_user": "ostar",
  "install_dir": "/opt/matrix"
}
```

排查「是不是当初配错了」时，先看这个文件，不用翻 YAML。

### 常用运维

```bash
cd /opt/matrix

docker compose ps                       # 状态
docker compose logs -f synapse          # 日志
docker compose restart synapse          # 改配置后重启

# 加普通用户（去掉 -a 就是普通用户）
docker compose exec synapse register_new_matrix_user \
  -c /data/homeserver.yaml -a -u alice http://localhost:8008
```

### 证书续期

acme.sh 已自动加 cron。**1Panel 模式下**，续期后需要把新证书同步到
1Panel 的站点目录，脚本会生成钩子 `/opt/matrix/renew-hook.sh`，
把它挂到 acme.sh 上：

```bash
/root/.acme.sh/acme.sh --install-cert -d chat.example.com \
  --key-file /etc/nginx/ssl/matrix/privkey.pem \
  --fullchain-file /etc/nginx/ssl/matrix/fullchain.pem \
  --reloadcmd "/opt/matrix/renew-hook.sh"
```

---

## 6. 参数速查

| 参数 | 说明 | 默认 |
|---|---|---|
| `--domain` | 主域名 | 必填 |
| `--ip` | 公网 IP | 自动探测 |
| `--web-host` | 网页前缀（决定 server_name） | `chat` |
| `--api-host` | API 前缀 | `<web>api` |
| `--admin-host` | 后台前缀 | `<web>ad` |
| `--cf-token` | Cloudflare Token | 环境变量 `CF_TOKEN` |
| `--admin-user` | 管理员用户名 | `ostar` |
| `--admin-pass` | 管理员密码 | 交互输入 |
| `--email` | 证书邮箱 | `admin@<domain>` |
| `--brand` | Element 显示名 | `Matrix Chat` |
| `--dir` | 安装目录 | `/opt/matrix` |
| `--max-upload` | 单文件上限（`0` = 不限） | `2G` |
| `--federation` | `closed` / `whitelist` / `open` | `closed` |
| `--federation-domains` | 白名单域名，逗号分隔 | — |
| `--allow-registration` | 开放注册 | 关闭 |
| `--allow-guests` | 允许游客浏览 | 关闭 |
| `--language` | 默认界面语言 | `zh_Hans` |
| `--theme` | 默认主题 `light`/`dark` | `light` |
| `--panel` | `auto` / `1panel` / `standalone` | `auto` |
| `--cert-mode` | `panel`（面板管）/ `acme`（脚本签） | `panel` |
| `--skip-dns` | 不建 DNS 记录 | — |
| `--skip-rtc` | 不装 LiveKit/coturn | — |
| `--no-proxy-web` | 网页域名也不走 CF 代理 | — |
| `--non-interactive` | 不提问 | — |
| `--force` | 重新生成密钥（**会换数据库密码**） | — |
| `--dry-run` | 只渲染不启动 | — |

---

## 7. 常见问题

### 7.0 已知限制（不是 bug）

| 现象 | 原因 | 怎么办 |
|---|---|---|
| 站点 HTTPS 的证书下拉显示「无数据」 | 1Panel 2.5.x 只列手动上传的证书，面板签发的不进候选 | 用「推送目录 + 钩子」，不需要在站点里选 |
| Element 首次打开是英文 | 该版本 Element 未采用 `default_language` | 右上角语言选择器切「简体中文」，浏览器会记住 |
| 建站后代号变成「域名+代号」 | 代号框自动拼接 | 先把代号框**清空**再打字 |
| 申请证书点确认没反应 | 勾选复选框会重绘表单，清掉已选的 DNS 账号 | 先勾复选框 → 填域名目录脚本 → 最后选 DNS 账号 |
| 续期报 `429 too many certificates` | 同一组域名 7 天限 5 张 | 测试用 `--staging`，或换一组域名 |
| 面板重装后申请证书没有可选项 | Acme/DNS 账户跟着丢了 | 重建这两个账户再申请 |

| 现象 | 原因 | 处理 |
|---|---|---|
| 公网 522 / 超时 | 云安全组没放行 80/443 | 第 1.3 节，`tcpdump` 抓包确认 |
| 1Panel 提示「未检测到 OpenResty」 | 宿主机有别的 nginx 占着 443 | `systemctl disable --now nginx` |
| Element 登录一直转圈 | 缺 `.well-known/matrix/client` | 第 3.8 节 |
| 通话打不开 / 双方看不到彼此 | 缺 `.well-known/matrix/server` | 第 3.8 节 |
| 大文件上传失败 | `chatapi` 走了橙云，或缺 `client_max_body_size 0` | 第 2.3 / 3.7 节 |
| 管理后台没弹登录框 | 密码访问开关没打开 | 第 3.6 节 |
| `password authentication failed` | `data/postgres` 残留旧密码 | `docker compose down && rm -rf data/postgres` 重跑 |
| Synapse 反复重启 | `/data` 属主不对 | `chown -R 991:991 data/synapse` |
| 证书续期后 1Panel 还是旧证书 | 没挂续期钩子 | 第 5 节「证书续期」 |

更多排错细节见 [PITFALLS.md](PITFALLS.md)。

---

## 8. 附录：为什么用 Let's Encrypt，不用 Cloudflare 的证书

在回答这个问题之前，先把「证书到底是怎么签出来的」讲清楚——
理解了原理，后面「为什么必须是公共 CA」就顺理成章了。

### 8.0 证书是怎么签出来的（原理）

#### 8.0.1 HTTPS 要解决两件事

```
① 加密     让中间人看不懂内容          →  靠密钥交换
② 身份     「对面真的是 chat.xxx 吗」    →  靠证书
```

第一件好办，双方临时协商密钥就行。**难的是第二件**——你怎么证明自己不是冒充者？

#### 8.0.2 证书的本质：一个受信任的第三方签名

浏览器出厂时就内置了一份**根证书列表**（Mozilla/微软/苹果维护），里面存着几十个 CA 的公钥。
判断逻辑是：

```
服务器出示证书
    ↓
证书上写着「我是 chat.xxx，由 XXX CA 签名」
    ↓
浏览器用内置的 CA 公钥验证这个签名
    ↓
签名对 → 相信这确实是 chat.xxx 的服务器
签名错 / CA 不在列表 → 红色警告
```

所以**自签名证书一定报错**：它自己给自己签名，不在任何浏览器的信任列表里。

#### 8.0.3 ACME 协议：CA 怎么确认你是域名主人

CA 看不见你的服务器。它只能用一个办法：**让你在一个"只有域名控制者才能改的地方"放一个随机值**。

这就是 ACME 协议的核心，有三种放法：

| 挑战方式 | 放哪 | CA 怎么查 | 需要什么 |
|---|---|---|---|
| **HTTP-01** | `http://域名/.well-known/acme-challenge/<token>` | 发 HTTP 请求去取 | **入站 80 端口可达** |
| **DNS-01** | `_acme-challenge.域名` 的 TXT 记录 | 查 DNS | 能改 DNS 记录的 API |
| TLS-ALPN-01 | 443 端口上的特殊 ALPN 握手 | 建 TLS 连接 | 入站 443 可达 |

这个值不是随便填的，它是：

```
token        = CA 给的随机串
thumbprint   = 你的账户公钥的 SHA-256
keyAuth      = token + "." + thumbprint
TXT 记录值    = base64url(SHA-256(keyAuth))
```

CA 自己算一遍，和 DNS 里查到的一致，就说明「这个账户确实控制这个域名」。

#### 8.0.4 我们为什么选 DNS-01

| 维度 | HTTP-01 | DNS-01（我们用） |
|---|---|---|
| 需要入站端口 | ✅ 需要 80 | ❌ 完全不需要 |
| 支持通配符 `*.x.com` | ❌ 不支持 | ✅ 支持 |
| 域名走 Cloudflare 橙云 | 🟡 要额外配置 | ✅ 无所谓 |
| 服务器被墙/无公网 IP | ❌ 签不了 | ✅ 只要出站能通 |

**最关键的是第一行**：部署时云安全组还没放行 80，用 HTTP-01 会直接失败；
DNS-01 只用到**出站 HTTPS**，所以端口没开也能签下来。

#### 8.0.5 完整流程（12 步）

以这台服务器为例：

```
①  脚本读 --cf-token，存进环境变量 CF_Token
        ↓
②  没装 acme.sh 就先装（curl get.acme.sh | sh）
    acme.sh 是一个纯 Shell 写的 ACME 客户端
        ↓
③  首次运行会向 Let's Encrypt 注册账户，生成账户密钥
        ↓
④  本地生成「证书私钥」和 CSR（证书签名请求）
    ★ 私钥从生成到落地，全程不出这台服务器
    CSR 里只有公钥和域名，没有私钥
        ↓
⑤  acme.sh 向 LE 下单：
    「我要给 chat / chatapi / chatad 三个域名签一张证书」
        ↓
⑥  LE 返回挑战：请证明你控制这三个域名
    每条挑战给一个 token
        ↓
⑦  acme.sh 用 CF Token 调 Cloudflare API，
    创建三条 TXT 记录：_acme-challenge.chat.xxx 等
        ↓
⑧  轮询公共 DNS，确认 TXT 已生效
    （Cloudflare API 是秒生效，但权威 DNS 传播需要几秒）
        ↓
⑨  通知 LE：「我准备好了，来查吧」
        ↓
⑩  LE 从权威 DNS 查这三条 TXT，逐条比对
        ↓
⑪  全部通过 → LE 用你提交的 CSR 签出证书
        ↓
⑫  acme.sh 下载证书链 → 存到 /root/.acme.sh/
    → --install-cert 复制到 /etc/nginx/ssl/matrix/
    → 顺手创建一条 TXT 记录的清理（acme.sh 会自动删）
```

对应到脚本实际执行的命令：

```bash
export CF_Token="$CF_TOKEN"
/root/.acme.sh/acme.sh --issue --dns dns_cf \
  -d chat.omxyes.cc.cd -d chatapi.omxyes.cc.cd -d chatad.omxyes.cc.cd \
  --keylength 2048

/root/.acme.sh/acme.sh --install-cert -d chat.omxyes.cc.cd \
  --key-file /etc/nginx/ssl/matrix/privkey.pem \
  --fullchain-file /etc/nginx/ssl/matrix/fullchain.pem \
  --reloadcmd "/opt/matrix/renew-hook.sh"
```

#### 8.0.6 证书文件里到底有什么

`fullchain.pem` 不是一张证书，是**一串**。这台机器上实测：

```bash
$ grep -c "BEGIN CERTIFICATE" /etc/nginx/ssl/matrix/fullchain.pem
3
```

三张分别是：

```
① 你的证书
   subject = CN = chat.omxyes.cc.cd
   issuer  = Let's Encrypt, CN = YR1        ← 由中间证书签

② 中间证书
   subject = Let's Encrypt, CN = YR1
   issuer  = ISRG, CN = Root YR             ← 由根证书签

③ 交叉签名的根（兼容老客户端）
```

**为什么必须带中间证书**：浏览器只内置根证书，不内置中间证书。
服务器如果把中间证书落下，链就断了，部分客户端（尤其安卓老版本）会报错。
所以要用 `fullchain.pem` 而不是只下发叶子证书。

`privkey.pem` 是私钥，**只存在于这台服务器**，`chmod 600` 保护。

#### 8.0.7 为什么有效期只有 90 天

这是 Let's Encrypt 刻意设计的：

- 缩短「私钥泄露后可被滥用」的窗口
- 强迫所有人做自动化（手动续证书根本撑不住 90 天一轮）

代价是必须自动化，所以配套了：

```
到期前 30 天开始尝试续期
每天检查 4 次（03:09 / 09:09 / 15:09 / 21:09）
= 最多 120 次重试机会
```

续期成功后触发 `--reloadcmd`，把新证书同步到 1Panel 的三个站点目录并重载 OpenResty（见第 5 节）。

#### 8.0.8 反复重装会不会签不出来

会。Let's Encrypt 有一条限制最容易踩：

> **New Certificates per Exact Set of Identifiers：同一组域名，每 7 天最多签 5 张。**
> 补充速度：每 34 小时恢复 1 张。

我们每次部署都是 `{chat, chatapi, chatad}` 这同一组名字，
所以**每次重装系统后重新签发，就消耗 1 次额度**。

```
3 次重装 = 用掉 3/5
第 6 次重装 → 报错：
  too many certificates (5) already issued for this exact set of identifiers
```

注意：普通的「续期」也算在内——官方明确说，非 ARI 方式的续期同样受这条限制约束。
（真正豁免的只有支持 ARI 的客户端自动续期。）

**三种应对：**

| 办法 | 做法 | 适用 |
|---|---|---|
| **① 备份恢复（推荐）** | 重装前打包 `/root/.acme.sh` 和 `/etc/nginx/ssl/matrix/`，装完还原 | 频繁重装调试 |
| **② 用测试环境** | 加 `--staging`，用 LE 的 staging 环境，**不限次数** | 验证流程（浏览器会报不受信任） |
| **③ 换一组名字** | 加一个子域，变成新的「identifiers 集合」 | 临时救急 |

**备份恢复具体做法：**

```bash
# 重装前（在旧系统上）
tar czf /root/cert-backup.tar.gz /root/.acme.sh /etc/nginx/ssl/matrix

# 重装后（把压缩包传回来，解压到根目录）
tar xzf /root/cert-backup.tar.gz -C /
# 再跑脚本，它会检测到证书已存在，直接复用，不消耗额度
```

脚本的证书步骤是幂等的：`acme.sh --install-cert` 成功就跳过签发，
所以只要证书文件还在，就不会重新申请。

#### 8.0.9 四个常见误解

| 误解 | 事实 |
|---|---|
| 「证书是绑 IP 的」 | 绑**域名**。同一 IP 上多个站点靠 SNI 区分 |
| 「一张证书只能一个域名」 | SAN 字段可以放很多个，我们用一张覆盖 3 个 |
| 「私钥会传给 CA」 | 不会。只传 CSR（含公钥），私钥永不出服务器 |
| 「证书过期数据就丢了」 | 不会。只是连不上，数据都在磁盘上 |

---

经常有人问：「Cloudflare 有免费证书，为什么还要折腾 Let's Encrypt？」

因为 **Cloudflare 有两种证书，很多人把它们混成一种**：

| Cloudflare 的产品 | 谁信任它 | 有效期 | 能装到自己服务器吗 |
|---|---|---|---|
| **边缘证书**（Universal SSL） | 浏览器 | 自动轮换 | ❌ 不归你管，CF 内部用 |
| **源服务器证书**（Origin CA） | **只有 Cloudflare** | 15 年 | ✅ 能装，但浏览器不认 |

真正能"装"的只有源服务器证书（Origin CA）。它确实诱人——15 年不用续——但这套架构里用不了。

### 8.1 决定性原因：`chatapi` 必须是灰云

三个域名的分工：

```
chat.域名       橙云（走 CF）  →  浏览器看到的是 CF 的边缘证书
chatad.域名     橙云（走 CF）  →  同上
chatapi.域名    灰云（直连）   →  浏览器/客户端直接连你的服务器
```

**`chatapi` 必须灰云**（第 2.3 节解释过：橙云会把上传卡在 100 MB）。灰云意味着流量不经过 Cloudflare，源服务器证书就没人验证了：

```
浏览器 ──直连──► 你的服务器（Origin CA 证书）
                    └─ 浏览器不认识这个 CA → 「您的连接不是私密连接」
```

而且不止浏览器：

| 谁连 `chatapi` | 用 Origin CA 会怎样 |
|---|---|
| Element 网页 | 证书错误，登录不了 |
| Element X 手机端 | 拒绝连接 |
| LiveKit 的 WSS | TLS 失败，通话打不开 |
| TURN 的 TLS | 同上 |
| **其他 Matrix 服务器（联邦）** | 它们直接连 `chatapi:443`，同样拒绝 |

联邦那条最关键：其他服务器**不经过你的 Cloudflare**，它们直连源站并校验证书。

### 8.2 两个绕不过去的物理限制

**① Cloudflare 代理只支持固定端口**

```
支持：80, 443, 8080, 8443, 2052, 2053, 2082, 2083, 2086, 2087, 2095, 2096
```

而通话用的：

```
TURN        3478（UDP/TCP）
LiveKit     50000-50100（UDP）
```

**这些端口根本无法走 Cloudflare 代理**，只能直连源站。

**② 媒体流是 UDP，没法代理**

信令（WSS）勉强能走橙云，媒体流（UDP）走不了。只要开通话，就必然有流量绕开 Cloudflare。

### 8.3 能不能混着用

技术上可以：

```
chat / chatad  →  Cloudflare 源服务器证书（15 年）
chatapi        →  Let's Encrypt
```

但收益为零，代价是：

| | 混用 | 全 Let's Encrypt（当前方案） |
|---|---|---|
| 证书数量 | 2 张 | 1 张，三个域名全覆盖 |
| 续期 | 一张要续、一张不用 | 统一走 acme.sh |
| nginx 配置 | 两套 `ssl_certificate` 路径 | 一套 |
| 排错 | 两张都可能配错 | 一张错了全错，好定位 |

而且 Let's Encrypt 的续期已经是全自动的（到期前 30 天开始，每天重试 4 次），15 年证书**并没有真正省掉什么工作**。

### 8.3b 为什么不让 1Panel 自己管证书

1Panel 确实能签发证书（Acme 账户 + DNS 账户 + 自动续签），但**它签发的证书绑不到站点**：
站点 → HTTPS → 「证书」下拉框显示「无数据」。

实测（1Panel 2.5.0）：

| 方式 | 站点下拉可见 | 能绑定 |
|---|---|---|
| 面板签发（DNS 账户） | ❌ 无数据 | ❌ |
| 手动上传 | ✅ 可见 | ✅ |

数据库里 `website_ssls.provider` 是关键：`dnsAccount` 不显示，`manual` 才显示。

所以脚本用的是：**acme.sh 签发 → 上传到面板 → 站点绑定**，三者缺一不可。
详细测试过程见仓库外的 `docs/测试流程/第4次脚本1panel证书测试/`。

> 顺带纠正一个常见误解：1Panel 的证书**本来就不落盘**，
> 内容存在数据库里，只有绑定站点或勾选「推送目录」时才写成文件。

### 8.3c 让 1Panel 接管证书的正确姿势（实测可行）

第 8.3b 说的限制是「站点下拉选不到面板证书」。这不代表 1Panel 管不了证书——
换一条路就能端到端跑通：**推送目录 + 执行脚本**。

申请证书时：

| 选项 | 填什么 |
|---|---|
| 推送证书到本地目录 | `/opt/1panel/www/sites/<代号>/ssl`（**站点正在用的那个目录**） |
| 申请证书之后执行脚本 | reload 命令（见下） |

```bash
SRC=/opt/1panel/www/sites/chat/ssl
for d in chatapi chatad; do
  cp "$SRC/fullchain.pem" "/opt/1panel/www/sites/$d/ssl/fullchain.pem"
  cp "$SRC/privkey.pem"   "/opt/1panel/www/sites/$d/ssl/privkey.pem"
done
ct=$(docker ps --format '{{.Names}}' | grep -i openresty | head -1)
docker exec "$ct" openresty -t && docker exec "$ct" openresty -s reload
```

实测（2.5.0）：签发 → 推送覆盖文件 → 脚本 reload → 站点自动用上新证书，HTTPS 200。
续期走同一条链路，同样自动生效。

| | 站点下拉绑定 | 推送目录 + 钩子 |
|---|---|---|
| 面板签发 | ✅ | ✅ |
| 自动续期 | ✅ | ✅ |
| 站点生效 | ❌ | ✅ |
| 首次人工 | 绑不上 | 配置一次 |

> 脚本默认就是这条路径（`--cert-mode panel`）。想回到 acme.sh 全自动方案，
> 加 `--cert-mode acme`。两种方式不要同时启用，否则会撞 Let's Encrypt 的签发限额。

### 8.4 什么情况下 Cloudflare 证书才合适

全部流量都走橙云的普通网站——浏览器根本看不到源站证书，用 15 年的确实省事。

但这套 Matrix 部署有多条绕开 Cloudflare 的链路（API、TURN、LiveKit 媒体、联邦），不适用。

### 8.5 一句话总结

> 只要 `chatapi` 必须灰云（为了上传无限制），就必须用**浏览器和全世界都信任**的证书。
> 那就只能是公共 CA，Let's Encrypt 是最成熟且免费的方案。
