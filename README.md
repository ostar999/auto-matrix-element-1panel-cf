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

## 目录

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
| 1 | 服务器 | 云厂商（某云厂商 / Vultr / 阿里云…） | 下单后邮件里给 IP、root 密码、SSH 端口 | 按配置 |
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
| 公网 IP | `203.0.113.10` | 实例详情页 |
| root 密码 | 一串随机字符 | 首次开通的邮件，或控制台「重置密码」 |
| SSH 端口 | 大多 `22`，有些是 `2222` 这种 | 实例详情页 / 邮件 |

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

### 2.6 证书模式（了解即可，不用改）

脚本申请的是 **Let's Encrypt 正式证书**（不是 Cloudflare 的源站证书），所以：

- Cloudflare → SSL/TLS → Overview 设成 **Full (strict)** 是安全的
- 无需在 Cloudflare 里上传任何证书
- 证书到期前 acme.sh 会自动续（第 5 节有同步钩子）

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

### 3.7 给 API 站点补两段配置

1Panel 生成的反向代理只转发 `/`，而 LiveKit 信令和大文件上传需要额外配置。

**文件位置**：`/opt/1panel/www/sites/chatapi/proxy/root.conf`

把内容替换成（把 `chatapi.example.com` 换成你的域名）：

```nginx
# LiveKit 信令 WebSocket（路径前缀必须剥掉）
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

# lk-jwt 签发 token
location ^~ /livekit/jwt/ {
    proxy_pass http://127.0.0.1:8080/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}

# Matrix API 本体：这两个参数是大文件上传的关键
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

> ⚠️ 在 1Panel 界面里改这个站点的「反向代理」，`root.conf` 会被重新生成，
> **上面这些会全部丢失**。改完界面记得回填。

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

`chatapi.example.com` 换成你的 API 域名。

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

全交互，会依次问你：

```
? 主域名: example.com
? 网页前缀（用户 ID 会用这个）[chat]:
? API 前缀 [chatapi]:
? 管理后台前缀 [chatad]:
? 管理员用户名 [ostar]:
? 管理员密码: ********
? 检测到 1Panel，网站是否交给 1Panel 管理? [y]:
```

### 4.2 带参数（半自动）

```bash
bash -c "$(curl -sSL .../install.sh)" _ \
  --domain example.com \
  --web-host chat \
  --cf-token "cfut_xxxxxxxx" \
  --admin-pass "你的密码" \
  --panel 1panel
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
| `--max-upload` | 单文件上限 | `2G` |
| `--panel` | `auto` / `1panel` / `standalone` | `auto` |
| `--skip-dns` | 不建 DNS 记录 | — |
| `--skip-rtc` | 不装 LiveKit/coturn | — |
| `--no-proxy-web` | 网页域名也不走 CF 代理 | — |
| `--non-interactive` | 不提问 | — |
| `--force` | 重新生成密钥（**会换数据库密码**） | — |
| `--dry-run` | 只渲染不启动 | — |

---

## 7. 常见问题

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
