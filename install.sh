#!/usr/bin/env bash
# =============================================================================
#  Matrix 全栈一键部署脚本
#  Synapse + Element + LiveKit + lk-jwt + coturn + nginx + Let's Encrypt
#
#  用法：
#    bash install.sh                       # 全交互
#    bash install.sh --domain example.com   # 只给域名，其余交互
#    bash install.sh --dry-run --domain ... # 只渲染配置，不启动
#
#  依赖：Ubuntu 20.04+ / Debian 11+，root 权限
# =============================================================================
set -Eeuo pipefail

SCRIPT_VERSION="1.2.0"
REPO="ostar999/auto-matrix-element-1panel-cf"
REPO_REF="${AUTO_MATRIX_REF:-main}"
TEMPLATE_CACHE="${AUTO_MATRIX_CACHE:-/tmp/auto-matrix-sh}"

# 本地执行（git clone 后 bash install.sh）指向脚本所在目录；
# 单行命令执行（bash -c "$(curl ...)"）时 BASH_SOURCE 为空，改为下载模板
SCRIPT_SRC="${BASH_SOURCE[0]:-}"
if [[ -n $SCRIPT_SRC && -f $SCRIPT_SRC ]]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SRC")" && pwd)"
else
  SCRIPT_DIR=""
fi
TEMPLATE_DIR="${SCRIPT_DIR:+$SCRIPT_DIR/templates}"

# ---------------------------------------------------------------- 默认参数
DOMAIN=""
WEB_HOST="chat"
API_HOST=""
ADMIN_HOST=""
CF_TOKEN="${CF_TOKEN:-}"
ADMIN_USER="ostar"
ADMIN_PASS=""
EMAIL=""
INSTALL_DIR="/opt/matrix"
BRAND="Matrix Chat"
FEDERATION="closed"
FEDERATION_DOMAINS=""
ALLOW_REGISTRATION="n"
ALLOW_GUESTS="n"
UI_LANG="zh_Hans"
UI_THEME="light"
TZ_NAME="Asia/Shanghai"
MAX_UPLOAD_SIZE="2G"

SKIP_DNS=0
SKIP_RTC=0
DRY_RUN=0
NON_INTERACTIVE=0
FORCE=0
PROXY_WEB=1
PROXY_ADMIN=1
PUBLIC_IP_OVERRIDE=""
STAGING=0
CERT_MODE="panel"
PANEL_MODE="auto"
PANEL_API_KEY=""

# ---------------------------------------------------------------- 输出工具
c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'
c_yel=$'\033[33m'; c_blue=$'\033[36m'; c_dim=$'\033[2m'

log()  { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s\n' "$c_blue" "$c_reset" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_reset" "$*"; }
warn() { printf '  %s!%s %s\n' "$c_yel" "$c_reset" "$*"; }
die()  { printf '\n%s✗ %s%s\n' "$c_red" "$*" "$c_reset" >&2; exit 1; }
dim()  { printf '  %s%s%s\n' "$c_dim" "$*" "$c_reset"; }

trap 'die "第 $LINENO 行执行失败，已中止"' ERR

# ---------------------------------------------------------------- 参数解析
usage() {
  cat <<EOF
Matrix 全栈部署 v$SCRIPT_VERSION

用法: bash install.sh [选项]

  --domain DOMAIN        主域名（必填），如 example.com
  --ip ADDR              服务器公网 IP（默认自动探测）
  --web-host PREFIX      Element 网页前缀，默认 chat
  --api-host PREFIX      API 前缀，默认 <web>api
  --admin-host PREFIX    管理后台前缀，默认 <web>ad
  --cf-token TOKEN       Cloudflare API Token（DNS-01 与建记录必需）
  --admin-user USER      管理员用户名，默认 ostar
  --admin-pass PASS      管理员密码（非交互模式必填）
  --email EMAIL          证书邮箱，默认 admin@<domain>
  --brand NAME           Element 显示名，默认 "Matrix Chat"
  --federation MODE      联邦: closed|whitelist|open，默认 closed
  --federation-domains D 白名单域名，逗号分隔（配合 whitelist）
  --allow-registration   开放注册（默认关闭）
  --allow-guests         允许游客浏览（默认关闭）
  --language LANG        默认界面语言，默认 zh_Hans（可选 en）
  --theme THEME          默认主题 light|dark，默认 light
  --dir PATH             安装目录，默认 /opt/matrix
  --max-upload SIZE      单文件上限，默认 2G
  --panel MODE           网站由谁托管: auto|1panel|standalone（默认 auto）
  --panel-api-key KEY    1Panel API Key，提供后可尝试自动建站（v2）
  --cert-mode MODE       证书由谁管理: panel|acme（默认 panel）
  --staging              用 Let's Encrypt 测试环境（不限次数，但浏览器不信任）
  --skip-dns             不自动创建 DNS 记录
  --skip-rtc             不部署 LiveKit / coturn（只做聊天）
  --no-proxy-web         网页域名也不走 Cloudflare 代理
  --non-interactive      不提问，全部用参数/默认值
  --force                覆盖已有配置与密钥
  --dry-run              只渲染配置，不启动服务
  -h, --help             显示本帮助
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)        DOMAIN="${2:?}"; shift 2 ;;
      --ip)            PUBLIC_IP_OVERRIDE="${2:?}"; shift 2 ;;
      --web-host)      WEB_HOST="${2:?}"; shift 2 ;;
      --api-host)      API_HOST="${2:?}"; shift 2 ;;
      --admin-host)    ADMIN_HOST="${2:?}"; shift 2 ;;
      --cf-token)      CF_TOKEN="${2:?}"; shift 2 ;;
      --admin-user)    ADMIN_USER="${2:?}"; shift 2 ;;
      --admin-pass)    ADMIN_PASS="${2:?}"; shift 2 ;;
      --email)         EMAIL="${2:?}"; shift 2 ;;
      --brand)         BRAND="${2:?}"; shift 2 ;;
      --federation)    FEDERATION="${2:?}"; shift 2 ;;
      --federation-domains) FEDERATION_DOMAINS="${2:?}"; shift 2 ;;
      --allow-registration) ALLOW_REGISTRATION=y; shift ;;
      --allow-guests)  ALLOW_GUESTS=y; shift ;;
      --language)      UI_LANG="${2:?}"; shift 2 ;;
      --theme)         UI_THEME="${2:?}"; shift 2 ;;
      --dir)           INSTALL_DIR="${2:?}"; shift 2 ;;
      --max-upload)    MAX_UPLOAD_SIZE="${2:?}"; shift 2 ;;
      --panel)         PANEL_MODE="${2:?}"; shift 2 ;;
      --panel-api-key) PANEL_API_KEY="${2:?}"; shift 2 ;;
      --cert-mode)     CERT_MODE="${2:?}"; shift 2 ;;
      --staging)       STAGING=1; shift ;;
      --skip-dns)      SKIP_DNS=1; shift ;;
      --skip-rtc)      SKIP_RTC=1; shift ;;
      --no-proxy-web)  PROXY_WEB=0; PROXY_ADMIN=0; shift ;;
      --non-interactive) NON_INTERACTIVE=1; shift ;;
      --force)         FORCE=1; shift ;;
      --dry-run)       DRY_RUN=1; shift ;;
      -h|--help)       usage; exit 0 ;;
      *) die "未知参数: $1（用 --help 查看用法）" ;;
    esac
  done
}

# ---------------------------------------------------------------- 交互输入
ask() { # ask VAR "提示" "默认值"
  local __var=$1 __q=$2 __def=${3:-} __ans=""
  if (( NON_INTERACTIVE )); then printf -v "$__var" '%s' "$__def"; return 0; fi
  if [[ -n $__def ]]; then
    read -r -p "  ? $__q [$__def]: " __ans || true
  else
    read -r -p "  ? $__q: " __ans || true
  fi
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

ask_secret() { # ask_secret VAR "提示" —— 输入时每个字符显示为 *
  local __var=$1 __q=$2 __ans="" __ch=""
  if (( NON_INTERACTIVE )); then return 0; fi
  printf '  ? %s: ' "$__q"
  while IFS= read -rsn1 __ch; do
    case $__ch in
      "")            break ;;                       # 回车
      $'\x7f'|$'\b')                                  # 退格
        if [[ -n $__ans ]]; then __ans=${__ans%?}; printf '\b \b'; fi ;;
      $'\x03')       printf '\n'; return 1 ;;          # Ctrl-C
      $'\x15')       while [[ -n $__ans ]]; do __ans=${__ans%?}; printf '\b \b'; done ;;  # Ctrl-U 清空
      *)             __ans+=$__ch; printf '*' ;;
    esac
  done
  printf '\n'
  # 去掉粘贴时可能混进来的终端转义序列（括号粘贴标记等）
  __ans=$(printf '%s' "$__ans" | sed -e 's/\x1b\[[0-9;]*[a-zA-Z~]//g' -e 's/\x1b\][^\x07]*\x07//g' -e 's/[[:cntrl:]]//g')
  printf -v "$__var" '%s' "$__ans"
}

yesno() { # yesno VAR "问题" 默认(y/n) —— 结果存 y/n
  local __var=$1 __q=$2 __def=${3:-n} __ans=""
  if (( NON_INTERACTIVE )); then printf -v "$__var" '%s' "$__def"; return 0; fi
  read -r -p "  ? $__q [$__def]: " __ans || true
  __ans=${__ans:-$__def}
  case $__ans in
    [Yy]*) printf -v "$__var" 'y' ;;
    *)     printf -v "$__var" 'n' ;;
  esac
}

confirm() { # confirm "问题" 默认(y/n)
  local q=$1 def=${2:-y} ans=""
  if (( NON_INTERACTIVE )); then return 0; fi
  read -r -p "  ? $q [$def]: " ans || true
  ans=${ans:-$def}
  [[ $ans =~ ^[Yy] ]]
}

# ---------------------------------------------------------------- 通用工具
have() { command -v "$1" >/dev/null 2>&1; }

rand_hex() { openssl rand -hex "$1"; }

detect_public_ip() {
  local ip
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -fsS4 --max-time 8 "$url" 2>/dev/null || true)
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "$ip"; return 0; }
  done
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')
  [[ -n $ip ]] || die "无法自动探测公网 IP，请用 --ip 指定"
  printf '%s' "$ip"
}

json_get() { # json_get '<json>' '<python expr>'
  python3 -c "
import json,sys
d=json.load(sys.stdin)
print($2)
" <<<"$1"
}

# ---------------------------------------------------------------- 预检

fetch_templates() {
  [[ -n $TEMPLATE_DIR && -d $TEMPLATE_DIR ]] && return 0

  step "获取配置模板"
  if [[ -d $TEMPLATE_CACHE/templates ]]; then
    TEMPLATE_DIR="$TEMPLATE_CACHE/templates"
    ok "复用缓存 $TEMPLATE_DIR"
    return 0
  fi

  mkdir -p "$TEMPLATE_CACHE"
  local url="https://codeload.github.com/$REPO/tar.gz/refs/heads/$REPO_REF"
  local tgz="$TEMPLATE_CACHE/src.tgz"
  dim "下载 $url"
  curl -fsSL --max-time 90 "$url" -o "$tgz" \
    || die "模板下载失败。可改用：git clone https://github.com/$REPO.git && cd auto-matrix-element-1panel-cf && sudo bash install.sh"
  tar xzf "$tgz" -C "$TEMPLATE_CACHE" --strip-components=1 \
    || die "模板解压失败"
  rm -f "$tgz"

  [[ -d $TEMPLATE_CACHE/templates ]] || die "压缩包里没有 templates 目录"
  TEMPLATE_DIR="$TEMPLATE_CACHE/templates"
  ok "模板已就绪（$TEMPLATE_DIR）"
}

preflight() {
  step "环境检查"

  [[ $EUID -eq 0 ]] || die "请用 root 运行（sudo bash install.sh）"
  ok "root 权限"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      ubuntu|debian) ok "系统 ${PRETTY_NAME}" ;;
      *) warn "未在 Ubuntu/Debian 上验证过（当前 ${ID:-unknown}），继续" ;;
    esac
  fi

  local arch; arch=$(uname -m)
  case $arch in
    x86_64|aarch64) ok "架构 $arch" ;;
    *) die "不支持的架构: $arch" ;;
  esac

  local mem_mb disk_gb
  mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  ok "内存 ${mem_mb}MB / 可用磁盘 ${disk_gb}GB"
  (( disk_gb >= 8 )) || die "磁盘可用不足 8GB，无法部署"
  (( mem_mb < 2000 )) && warn "内存 < 2GB，脚本会自动创建 swap"

  if have ss; then
    local p owner
    for p in 80 443; do
      if ss -tlnH "sport = :$p" 2>/dev/null | grep -q .; then
        owner=$(ss -tlnpH "sport = :$p" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -1 | tr -d 'users:(("')
        if [[ $owner == nginx* && -d $INSTALL_DIR/nginx ]]; then
          ok "端口 $p 由本机已有的 Matrix nginx 占用，将复用"
        elif [[ $owner == *openresty* || $owner == opnty* || $owner == openresty* ]]; then
          ok "端口 $p 由 1Panel 的 OpenResty 占用（1Panel 模式）"
          [[ $PANEL_MODE == standalone ]] && die "当前是 standalone 模式，但 80/443 被 1Panel 占着。请用 --panel 1panel，或先停掉 OpenResty"
        else
          die "端口 $p 被 ${owner:-未知进程} 占用，请先停掉它（例如 1Panel 的 OpenResty）"
        fi
      else
        ok "端口 $p 空闲"
      fi
    done
  fi

  fetch_templates
  [[ -d $TEMPLATE_DIR ]] || die "找不到模板目录: $TEMPLATE_DIR"
  ok "模板目录 $TEMPLATE_DIR"
}

ensure_swap() {
  local mem_mb swap_mb
  mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  swap_mb=$(awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo)
  (( mem_mb >= 2000 )) && return 0
  if (( swap_mb >= 1024 )); then ok "已有 swap ${swap_mb}MB"; return 0; fi

  step "创建 2GB swap（内存 ${mem_mb}MB 偏小）"
  if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile
    mkswap -q /swapfile
  fi
  swapon /swapfile 2>/dev/null || true
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "swap 已启用"
}

ensure_docker() {
  step "Docker"
  if have docker; then
    ok "Docker $(docker --version | awk '{print $3}' | tr -d ,)"
  else
    dim "安装 Docker（约 1-2 分钟）"
    curl -fsSL https://get.docker.com | sh >/tmp/docker-install.log 2>&1 \
      || { tail -20 /tmp/docker-install.log; die "Docker 安装失败"; }
    ok "Docker 已安装"
  fi
  docker compose version >/dev/null 2>&1 || die "缺少 docker compose 插件"
  ok "docker compose 可用"
  systemctl enable --now docker >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- DNS
cf_api() { # cf_api METHOD PATH [BODY]
  local m=$1
  local p=$2
  local body=${3:-}
  local -a args=( -sS -X "$m" "https://api.cloudflare.com/client/v4$p"
    -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" )
  [[ -n $body ]] && args+=( -d "$body" )
  curl "${args[@]}"
}

dns_setup() {
  step "Cloudflare DNS"
  if (( SKIP_DNS )); then warn "已按 --skip-dns 跳过"; return 0; fi
  [[ -n $CF_TOKEN ]] || die "缺少 Cloudflare Token。请加 --cf-token，或在交互模式里按提示输入"

  local zid

  local resp
  resp=$(cf_api GET "/zones?name=$DOMAIN")
  zid=$(json_get "$resp" "d['result'][0]['id'] if d.get('success') and d.get('result') else ''" 2>/dev/null || true)
  [[ -n $zid ]] || die "在 Cloudflare 找不到域名 $DOMAIN（或 Token 没有 Zone:Read 权限）"
  ok "zone id: $zid"

  local recs=("$WEB_HOST:$PROXY_WEB" "$API_HOST:0" "$ADMIN_HOST:$PROXY_ADMIN")
  for item in "${recs[@]}"; do
    local host=${item%%:*} prox=${item##*:} fqdn ip
    fqdn="$host.$DOMAIN"
    [[ $host == "$API_HOST" ]] && prox=0

    local existing
    existing=$(cf_api GET "/zones/$zid/dns_records?type=A&name=$fqdn")
    local old_id old_ip
    old_id=$(json_get "$existing" "d['result'][0]['id'] if d.get('result') else ''" 2>/dev/null || true)
    old_ip=$(json_get "$existing" "d['result'][0]['content'] if d.get('result') else ''" 2>/dev/null || true)

    if [[ -n $old_id ]]; then
      if [[ $old_ip == "$PUBLIC_IP" ]]; then
        ok "$fqdn 已存在且指向本机，跳过"
        continue
      fi
      warn "$fqdn 已存在，指向 $old_ip（不是本机 $PUBLIC_IP）"
      if (( NON_INTERACTIVE )); then
        die "DNS 冲突：$fqdn。换前缀或先删除该记录"
      fi
      if ! confirm "强制覆盖这条记录？（会抢走那台服务器的解析）" n; then
        die "已中止。请换一个前缀重跑"
      fi
      cf_api PATCH "/zones/$zid/dns_records/$old_id" \
        "{\"content\":\"$PUBLIC_IP\",\"proxied\":$([[ $prox == 1 ]] && echo true || echo false)}" >/dev/null
      ok "$fqdn 已覆盖为 $PUBLIC_IP"
      continue
    fi

    local body
    body="{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$PUBLIC_IP\",\"ttl\":1,\"proxied\":$([[ $prox == 1 ]] && echo true || echo false),\"comment\":\"matrix\"}"
    local created
    created=$(cf_api POST "/zones/$zid/dns_records" "$body")
    if [[ $(json_get "$created" "d.get('success')" 2>/dev/null || echo False) == "True" ]]; then
      ok "$fqdn -> $PUBLIC_IP $([[ $prox == 1 ]] && echo '[橙云]' || echo '[灰云]')"
    else
      die "创建 $fqdn 失败: $(json_get "$created" "d.get('errors')" 2>/dev/null)"
    fi
  done
}


subst() { # subst 模板 目标
  cp "$1" "$2"
  python3 - "$2" <<'PYPATCH'
import os, sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
for k, v in os.environ.items():
    if k.startswith("PH_"):
        token = "@" + k[3:] + "@"
        s = s.replace(token, v)
open(path, "w", encoding="utf-8").write(s)
PYPATCH
}

# ---------------------------------------------------------------- 渲染
load_or_create_secrets() {
  # .env 里保存全部密钥；缺哪个补哪个（幂等，重跑不会丢密钥）
  if [[ -f $INSTALL_DIR/.env ]]; then
    set -a
    # shellcheck disable=SC1091
    . "$INSTALL_DIR/.env"
    set +a
  fi

  local v changed=0
  for v in SECRET_DB SECRET_REG SECRET_MAC SECRET_FORM SECRET_TURN SECRET_AS SECRET_HS LIVEKIT_KEY LIVEKIT_SECRET; do
    [[ -n ${!v:-} ]] && continue
    case $v in
      LIVEKIT_KEY) printf -v "$v" '%s' "API$(rand_hex 6)" ;;
      SECRET_DB)   printf -v "$v" '%s' "$(rand_hex 16)" ;;
      *)           printf -v "$v" '%s' "$(rand_hex 32)" ;;
    esac
    changed=1
  done

  if (( changed )) || [[ ! -f $INSTALL_DIR/.env ]]; then
    cat > "$INSTALL_DIR/.env" <<EOF
# 由 install.sh 生成于 $(date '+%F %T')
DOMAIN=$DOMAIN
WEB_FQDN=$WEB_FQDN
API_FQDN=$API_FQDN
ADMIN_FQDN=$ADMIN_FQDN
TZ=$TZ_NAME

# 数据库
POSTGRES_PASSWORD=$SECRET_DB
SECRET_DB=$SECRET_DB
# Synapse 密钥
SECRET_REG=$SECRET_REG
SECRET_MAC=$SECRET_MAC
SECRET_FORM=$SECRET_FORM
# TURN
SECRET_TURN=$SECRET_TURN
# LiveKit
LIVEKIT_KEY=$LIVEKIT_KEY
LIVEKIT_SECRET=$LIVEKIT_SECRET
# lk-jwt application service
SECRET_AS=$SECRET_AS
SECRET_HS=$SECRET_HS
EOF
    chmod 600 "$INSTALL_DIR/.env"
    ok "密钥已保存到 .env"
  else
    ok "复用 .env 中的密钥"
  fi
}

render_files() {
  step "生成配置"

  mkdir -p "$INSTALL_DIR"/{data/synapse,data/postgres,synapse,element,livekit,coturn,nginx}

  (( FORCE )) && rm -f "$INSTALL_DIR/.env"
  load_or_create_secrets

  # ---- 条件块 ----
  if (( SKIP_RTC )); then
    PH_TURN_BLOCK="# （未启用通话，TURN 已跳过）"
    PH_RTC_EXPERIMENTAL=""
    PH_MATRIX_RTC_BLOCK=""
    PH_APP_SERVICE_BLOCK=""
    PH_LIVEKIT_BLOCK="    # （未启用通话，LiveKit 路径已跳过）"
  else
    PH_TURN_BLOCK="turn_uris:
  - \"turn:$API_FQDN?transport=udp\"
  - \"turn:$API_FQDN?transport=tcp\"
turn_shared_secret: \"$SECRET_TURN\"
turn_user_lifetime: 1h
turn_allow_guests: false"
    PH_RTC_EXPERIMENTAL="  msc4502_enabled: true
  msc4512_enabled: true"
    PH_MATRIX_RTC_BLOCK="matrix_rtc:
  transports:
    - type: m.livekit
      url: \"wss://$API_FQDN/livekit/sfu\"
    - type: livekit
      url: \"wss://$API_FQDN/livekit/sfu\"
      livekit_service_url: \"https://$API_FQDN/livekit/jwt\""
    PH_APP_SERVICE_BLOCK="app_service_config_files:
  - /data/lk-jwt-registration.yaml"
    PH_LIVEKIT_BLOCK="    # LiveKit 信令（WebSocket），路径前缀需要剥掉
    location /livekit/sfu/ {
        proxy_pass http://127.0.0.1:7880/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        \"upgrade\";
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering    off;
    }

    location /livekit/jwt/ {
        proxy_pass http://127.0.0.1:8080/;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }
"
  fi

  # ---- 联邦 / 注册 / 游客 / 界面 ----
  case $FEDERATION in
    closed)
      PH_FEDERATION_BLOCK="# 联邦：关闭（仅本服务器用户互通）
federation_domain_whitelist: []
trusted_key_servers: []
suppress_key_server_warning: true" ;;
    whitelist)
      local doms="" d
      IFS=',' read -ra _doms <<< "$FEDERATION_DOMAINS"
      for d in "${_doms[@]}"; do
        d=$(echo "$d" | tr -d ' ')
        [[ -n $d ]] && doms+="  - \"$d\"
"
      done
      PH_FEDERATION_BLOCK="# 联邦：白名单
federation_domain_whitelist:
${doms}suppress_key_server_warning: true" ;;
    open)
      PH_FEDERATION_BLOCK="# 联邦：开放（任何 Matrix 服务器都能互通）" ;;
  esac

  if [[ $ALLOW_REGISTRATION == y ]]; then
    PH_REGISTRATION_BLOCK="enable_registration: true
enable_registration_without_verification: true"
  else
    PH_REGISTRATION_BLOCK="enable_registration: false"
  fi

  [[ $ALLOW_GUESTS == y ]] && PH_ALLOW_GUESTS=true || PH_ALLOW_GUESTS=false
  [[ $ALLOW_GUESTS == y ]] && PH_DISABLE_GUESTS=false || PH_DISABLE_GUESTS=true

  export PH_DOMAIN=$DOMAIN PH_WEB_FQDN=$WEB_FQDN PH_API_FQDN=$API_FQDN PH_ADMIN_FQDN=$ADMIN_FQDN
  export PH_WEB_HOST=$WEB_HOST PH_API_HOST=$API_HOST PH_ADMIN_HOST=$ADMIN_HOST
  export PH_SECRET_DB=$SECRET_DB PH_SECRET_REG=$SECRET_REG PH_SECRET_MAC=$SECRET_MAC
  export PH_SECRET_FORM=$SECRET_FORM PH_SECRET_TURN=$SECRET_TURN
  export PH_SECRET_AS=$SECRET_AS PH_SECRET_HS=$SECRET_HS
  export PH_LIVEKIT_KEY=$LIVEKIT_KEY PH_LIVEKIT_SECRET=$LIVEKIT_SECRET
  export PH_BRAND=$BRAND PH_MAX_UPLOAD_SIZE=$MAX_UPLOAD_SIZE
  export PH_FEDERATION_BLOCK PH_REGISTRATION_BLOCK PH_ALLOW_GUESTS PH_DISABLE_GUESTS
  case $UI_LANG in
    zh-CN|zh_CN|zh)   UI_LANG=zh_Hans ;;
    zh-TW|zh_TW|zh-Hant) UI_LANG=zh_Hant ;;
  esac
  export PH_UI_LANG=$UI_LANG PH_UI_THEME=$UI_THEME
  export PH_SSL_CERT=$SSL_CERT PH_SSL_KEY=$SSL_KEY PH_HTPASSWD=$HTPASSWD
  export PH_TURN_BLOCK PH_RTC_EXPERIMENTAL PH_MATRIX_RTC_BLOCK PH_APP_SERVICE_BLOCK PH_LIVEKIT_BLOCK


  subst "$TEMPLATE_DIR/docker-compose.yaml.tmpl"      "$INSTALL_DIR/docker-compose.yaml"
  subst "$TEMPLATE_DIR/homeserver.yaml.tmpl"          "$INSTALL_DIR/synapse/homeserver.yaml"
  subst "$TEMPLATE_DIR/element.config.json.tmpl"      "$INSTALL_DIR/element/config.json"
  subst "$TEMPLATE_DIR/livekit.yaml.tmpl"             "$INSTALL_DIR/livekit/livekit.yaml"
  subst "$TEMPLATE_DIR/lk-jwt-registration.yaml.tmpl" "$INSTALL_DIR/livekit/lk-jwt-registration.yaml"
  subst "$TEMPLATE_DIR/turnserver.conf.tmpl"          "$INSTALL_DIR/coturn/turnserver.conf"
  subst "$TEMPLATE_DIR/nginx-web.conf.tmpl"           "$INSTALL_DIR/nginx/$WEB_FQDN.conf"
  subst "$TEMPLATE_DIR/nginx-api.conf.tmpl"           "$INSTALL_DIR/nginx/$API_FQDN.conf"
  subst "$TEMPLATE_DIR/nginx-admin.conf.tmpl"         "$INSTALL_DIR/nginx/$ADMIN_FQDN.conf"

  if [[ $CERT_MODE == panel && $PANEL_MODE == 1panel ]]; then
    panel_cert_setup
  fi

  chmod 644 "$INSTALL_DIR"/synapse/homeserver.yaml "$INSTALL_DIR"/element/config.json \
            "$INSTALL_DIR"/livekit/*.yaml "$INSTALL_DIR"/coturn/turnserver.conf
  chown -R 991:991 "$INSTALL_DIR/data/synapse"

  cat > "$INSTALL_DIR/install-manifest.json" <<JSON
{
  "version": "$SCRIPT_VERSION",
  "installed_at": "$(date -Iseconds)",
  "domain": "$DOMAIN",
  "web_host": "$WEB_HOST",
  "api_host": "$API_HOST",
  "admin_host": "$ADMIN_HOST",
  "brand": "$BRAND",
  "max_upload_size": "$MAX_UPLOAD_SIZE",
  "federation": "$FEDERATION",
  "federation_domains": "$FEDERATION_DOMAINS",
  "allow_registration": $([[ $ALLOW_REGISTRATION == y ]] && echo true || echo false),
  "allow_guests": $([[ $ALLOW_GUESTS == y ]] && echo true || echo false),
  "language": "$UI_LANG",
  "theme": "$UI_THEME",
  "panel_mode": "$PANEL_MODE",
  "rtc": $([[ $SKIP_RTC == 1 ]] && echo false || echo true),
  "admin_user": "$ADMIN_USER",
  "install_dir": "$INSTALL_DIR"
}
JSON
  ok "安装参数已写入 install-manifest.json"

  ok "容器配置已生成"

  if (( SKIP_RTC )); then
    # 没启用通话时把相关服务从 compose 里摘掉
    python3 - "$INSTALL_DIR/docker-compose.yaml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"\n  livekit:\n(?:.*\n)*?(?=\n  lk-jwt:)", "\n", s)
s = re.sub(r"\n  lk-jwt:\n(?:.*\n)*?(?=\n  coturn:)", "\n", s)
s = re.sub(r"\n  coturn:\n(?:.*\n)*?(?=\nnetworks:)", "\n", s)
s = s.replace("      - ./livekit/lk-jwt-registration.yaml:/data/lk-jwt-registration.yaml:ro\n", "")
open(p, "w").write(s)
PY
    ok "已按 --skip-rtc 精简 compose"
  fi
}


# ---------------------------------------------------------------- 1Panel 模式
panel_detected() {
  [[ -d /opt/1panel ]] && systemctl is-active --quiet 1panel-core 2>/dev/null
}

panel_openresty_ok() {
  docker ps --format '{{.Image}}' 2>/dev/null | grep -q '1panel/openresty'
}

choose_panel_mode() {
  [[ $PANEL_MODE != auto ]] && return 0

  if panel_detected; then
    if (( NON_INTERACTIVE )); then
      PANEL_MODE=1panel
    elif confirm "检测到 1Panel，网站是否交给 1Panel 管理（推荐 Yes）?" y; then
      PANEL_MODE=1panel
    else
      PANEL_MODE=standalone
    fi
  else
    PANEL_MODE=standalone
    if (( ! NON_INTERACTIVE )) && confirm "未检测到 1Panel，是否先安装 1Panel 再用它管理网站?" n; then
      PANEL_MODE=install-1panel
    fi
  fi
  ok "网站托管模式: $PANEL_MODE"
}

install_1panel() {
  step "安装 1Panel"
  warn "1Panel 安装会占用 80/443（它自带 OpenResty），并在装完后由你初始化管理员"
  if ! confirm "确认安装 1Panel?" y; then
    PANEL_MODE=standalone
    warn "已取消，改用独立 nginx"
    return 0
  fi
  curl -fsSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh -o /tmp/1panel-install.sh \
    || die "1Panel 安装脚本下载失败"
  bash /tmp/1panel-install.sh || die "1Panel 安装失败"
  ok "1Panel 已安装，请先用 '1pctl user-info' 拿到地址完成初始化"
  die "初始化 1Panel 后，重新运行本脚本（它会自动识别 1Panel 管理）"
}


# ---------------------------------------------------------------- 面板管证书
panel_cert_setup() {
  local pdir="$INSTALL_DIR/panel-cert"
  mkdir -p "$pdir"

  # ① 占位自签证书：让站点能先开启 HTTPS，从而把 nginx 指向 sites/<代号>/ssl/
  if [[ ! -f $pdir/placeholder.crt ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -subj "/CN=$WEB_FQDN" \
      -addext "subjectAltName=DNS:$WEB_FQDN,DNS:$API_FQDN,DNS:$ADMIN_FQDN" \
      -keyout "$pdir/placeholder.key" -out "$pdir/placeholder.crt" >/dev/null 2>&1 \
      && ok "占位自签证书已生成: $pdir/placeholder.crt" \
      || warn "占位证书生成失败，可跳过（用任意证书先开 HTTPS 也行）"
  fi

  # ② 续期钩子：把证书复制到三个站点 + 重载 OpenResty
  cat > "$pdir/ssl-sync-hook.sh" <<HOOK
#!/bin/bash
# 1Panel 证书签发/续期后自动执行
# 用法：面板申请证书时勾选「申请证书之后执行脚本」，把本文件内容粘进去
SRC=/opt/1panel/www/sites/$WEB_HOST/ssl
for d in $API_HOST $ADMIN_HOST; do
  dst="/opt/1panel/www/sites/\$d/ssl"
  [ -d "\$dst" ] || continue
  cp "\$SRC/fullchain.pem" "\$dst/fullchain.pem" 2>/dev/null || true
  cp "\$SRC/privkey.pem"   "\$dst/privkey.pem"   2>/dev/null || true
done
ct=\$(docker ps --format '{{.Names}}' | grep -i openresty | head -1)
if [ -n "\$ct" ]; then
  docker exec "\$ct" openresty -t >/dev/null 2>&1 && docker exec "\$ct" openresty -s reload
fi
echo "\$(date -Is) ssl-sync-hook done" >> /var/log/ssl-sync-hook.log
HOOK
  chmod 755 "$pdir/ssl-sync-hook.sh"
  ok "续期钩子已生成: $pdir/ssl-sync-hook.sh"

  # ③ 三个 nginx 片段一键写入（站点建好后执行）
  cat > "$pdir/apply-snippets.sh" <<'SNIP'
#!/bin/bash
# 用法（站点建好之后执行一次）：bash /opt/matrix/panel-cert/apply-snippets.sh
set -e
WEB=__WEB__
API=__API__
BASE=/opt/1panel/www/sites
[ -d "$BASE/$WEB" ] || { echo "找不到站点目录 $BASE/$WEB，请先在面板建好三个站点"; exit 1; }
[ -d "$BASE/$API" ] || { echo "找不到站点目录 $BASE/$API，请先在面板建好三个站点"; exit 1; }

cat > "$BASE/$WEB/proxy/zz-wellknown.conf" <<EOS
location = /.well-known/matrix/client {
    default_type application/json;
    add_header Access-Control-Allow-Origin "*" always;
    return 200 '{"m.homeserver":{"base_url":"https://__APIFQDN__"}}';
}
location = /.well-known/matrix/server {
    default_type application/json;
    add_header Access-Control-Allow-Origin "*" always;
    return 200 '{"m.server":"__APIFQDN__:443"}';
}
EOS

cat > "$BASE/$API/proxy/zz-upload.conf" <<'EOS'
client_max_body_size 0;
proxy_request_buffering off;
EOS

cat > "$BASE/$API/proxy/zz-livekit.conf" <<'EOS'
location /livekit/sfu/ {
    proxy_pass http://127.0.0.1:7880/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 3600s;
    proxy_buffering off;
}
location /livekit/jwt/ {
    proxy_pass http://127.0.0.1:8080/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
}
EOS

ct=$(docker ps --format '{{.Names}}' | grep -i openresty | head -1)
if [ -n "$ct" ]; then
  docker exec "$ct" openresty -t && docker exec "$ct" openresty -s reload
fi
echo "✓ 三个片段已写入并重载 OpenResty"
SNIP
  sed -i "s/__WEB__/$WEB_HOST/; s/__API__/$API_HOST/; s/__APIFQDN__/$API_FQDN/" "$pdir/apply-snippets.sh"
  chmod 755 "$pdir/apply-snippets.sh"
  ok "nginx 片段脚本已生成: $pdir/apply-snippets.sh"

  cat <<EOF

  ${c_yel}证书由 1Panel 管理（默认模式）${c_reset}

  ① 面板建 3 个站点（反向代理，见上）后，先上传一张「占位证书」：
     证书 → 上传证书
       名称   placeholder
       证书   $pdir/placeholder.crt
       私钥   $pdir/placeholder.key
     三个站点 → 配置 → HTTPS → 打开 → 选 placeholder → 保存
     （这一步只会让 nginx 指向 /www/sites/<代号>/ssl/，稍后会被正式证书覆盖）

  ② 面板申请正式证书：
     证书 → 申请证书
       主域名   $WEB_FQDN
       其他域名 $API_FQDN, $ADMIN_FQDN
       DNS 账号 你创建的 Cloudflare 账户
       自动续签 ✅
       推送证书到本地目录 ✅ → /opt/1panel/www/sites/$WEB_HOST/ssl
       申请证书之后执行脚本 ✅ → 把 $pdir/ssl-sync-hook.sh 的内容粘进去

  ③ 点「确认」。面板会：签发 → 推送覆盖 → 执行脚本 → 三个站点自动生效

  之后每次续期都走同一条链路，无需人工干预。

EOF
}

panel_prepare() {
  step "1Panel 模式准备"

  if systemctl is-active --quiet nginx 2>/dev/null; then
    warn "检测到宿主机 nginx 正在运行并占用 80/443"
    dim "1Panel 的 OpenResty 也是要 80/443 的，两者只能留一个"
    dim "切换到 1Panel 管理：systemctl disable --now nginx"
    die "请先停掉宿主机 nginx 再重跑"
  fi

  panel_openresty_ok || die "未检测到 1Panel 的 OpenResty。请先到 应用商店 → Web 服务器 安装 OpenResty，再重跑本脚本"

  ok "1Panel OpenResty 就绪"
  dim "站点配置已生成在 $INSTALL_DIR/nginx/"


  cat > "$INSTALL_DIR/renew-hook.sh" <<'HOOK'
#!/bin/bash
# acme.sh 续期后：把证书同步到 1Panel 各站点目录，再重载 OpenResty
set -e
SRC=/etc/nginx/ssl/matrix
for d in /opt/1panel/www/sites/*/ssl; do
  [ -d "$d" ] || continue
  cp "$SRC/fullchain.pem" "$d/fullchain.pem" 2>/dev/null || true
  cp "$SRC/privkey.pem"  "$d/privkey.pem" 2>/dev/null || true
done
ct=$(docker ps --format '{{.Names}}' | grep -i openresty | head -1)
if [ -n "$ct" ]; then docker exec "$ct" openresty -s reload; fi
echo "renew-hook done"
HOOK
  chmod +x "$INSTALL_DIR/renew-hook.sh"
  ok "续期钩子已生成: $INSTALL_DIR/renew-hook.sh"

  if [[ $CERT_MODE == panel ]]; then
    CERT_UPLOAD_HINT="       证书: $INSTALL_DIR/panel-cert/placeholder.crt
       私钥: $INSTALL_DIR/panel-cert/placeholder.key
       （占位证书，正式证书随后在面板申请，见下方证书步骤）"
    HOOK_HINT="  （证书由面板管理：占位证书上传、正式证书申请与续期钩子，
     见下方『证书由 1Panel 管理』一段）"
  else
    CERT_UPLOAD_HINT="       证书: $SSL_CERT
       私钥: $SSL_KEY"
    HOOK_HINT="  6) 续期钩子：把 acme.sh 的 reloadcmd 指向
     $INSTALL_DIR/renew-hook.sh（同步证书到 1Panel 各站点并重载）"
  fi

  cat <<EOF

  ${c_yel}在 1Panel 里建 3 个站点（约 3 分钟）${c_reset}

  1) 网站 → 创建 → 反向代理，建三个站点：

       域名                     代理地址
       ---------------------------------------------
       $WEB_FQDN      http://127.0.0.1:9180
       $API_FQDN      http://127.0.0.1:9108
       $ADMIN_FQDN    http://127.0.0.1:9182

  2) 证书 → 上传证书，填：
${CERT_UPLOAD_HINT}
     然后各站点 → HTTPS → 打开开关 → 保存

  3) 后台站点 → 密码访问 → 创建用户 → 打开开关（否则管理面板裸奔）

  4) API 站点：把 $INSTALL_DIR/nginx/$API_FQDN.conf 里的
     /livekit/sfu/、/livekit/jwt/ 两个 location 和
     client_max_body_size 0 / proxy_request_buffering off
     写进 1Panel 的 /www/sites/<代号>/proxy/root.conf
     （UI 改代理会重新生成该文件，改完要回填）

  5) 网页站点：加 /www/sites/<代号>/proxy/zz-wellknown.conf，
     内容见 $INSTALL_DIR/nginx/ 下的片段

${HOOK_HINT}

  脚本已经把上述片段都生成好了，照着贴即可。

EOF
}

# ---------------------------------------------------------------- 证书
install_acme() {
  if [[ -f /root/.acme.sh/acme.sh ]]; then ok "acme.sh 已存在"; return 0; fi
  dim "安装 acme.sh"
  curl -fsS https://get.acme.sh | sh -s email="$EMAIL" >/tmp/acme-install.log 2>&1 \
    || { tail -20 /tmp/acme-install.log; die "acme.sh 安装失败"; }
  ok "acme.sh 已安装"
}

issue_cert() {
  step "申请证书（DNS-01）"
  [[ -n $CF_TOKEN ]] || die "证书申请需要 Cloudflare Token（DNS-01）"

  mkdir -p "$(dirname "$SSL_CERT")"
  install_acme

  export CF_Token="$CF_TOKEN"
  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

  local args=(-d "$WEB_FQDN" -d "$API_FQDN" -d "$ADMIN_FQDN")
  local stage_args=()
  if (( STAGING )); then
    stage_args=(--staging)
    warn "使用 Let's Encrypt 测试环境：证书不受浏览器信任，仅用于流程验证"
  fi
  local primary="$WEB_FQDN"

  if /root/.acme.sh/acme.sh --install-cert -d "$primary" \
       --key-file "$SSL_KEY" --fullchain-file "$SSL_CERT" \
       --reloadcmd "systemctl reload nginx 2>/dev/null || true" >/dev/null 2>&1; then
    ok "复用已签发的证书"
  else
    dim "签发 $primary（共 3 个域名，约 1 分钟）"
    /root/.acme.sh/acme.sh --issue --dns dns_cf "${args[@]}" --keylength 2048 --force "${stage_args[@]}" \
      >/tmp/acme-issue.log 2>&1 || { tail -25 /tmp/acme-issue.log; die "证书签发失败"; }
    ok "证书签发成功"
    /root/.acme.sh/acme.sh --install-cert -d "$primary" \
      --key-file "$SSL_KEY" --fullchain-file "$SSL_CERT" \
      --reloadcmd "systemctl reload nginx 2>/dev/null || true" >/tmp/acme-install-cert.log 2>&1 \
      || { tail -20 /tmp/acme-install-cert.log; die "证书安装失败"; }
  fi

  chmod 600 "$SSL_KEY"
  ok "证书已安装到 $(dirname "$SSL_CERT")"
}

# ---------------------------------------------------------------- 反向代理
ensure_nginx() {
  step "安装 nginx"
  if have nginx; then
    ok "nginx $(nginx -v 2>&1 | awk -F/ '{print $2}') 已存在"
    return 0
  fi
  dim "apt 安装 nginx"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx >/dev/null
  systemctl enable --now nginx >/dev/null 2>&1 || true
  ok "nginx 已安装"
}

setup_nginx() {
  step "配置站点"

  mkdir -p "$(dirname "$HTPASSWD")"
  local hash; hash=$(openssl passwd -apr1 "$ADMIN_PASS")
  printf '%s:%s\n' "$ADMIN_USER" "$hash" > "$HTPASSWD"
  chmod 640 "$HTPASSWD"; chown root:www-data "$HTPASSWD" 2>/dev/null || true

  for f in "$WEB_FQDN" "$API_FQDN" "$ADMIN_FQDN"; do
    cp "$INSTALL_DIR/nginx/$f.conf" "/etc/nginx/sites-available/$f.conf"
    ln -sf "/etc/nginx/sites-available/$f.conf" "/etc/nginx/sites-enabled/$f.conf"
    ok "站点 $f 已启用"
  done
  rm -f /etc/nginx/sites-enabled/default

  nginx -t >/dev/null 2>&1 || { nginx -t; die "nginx 配置有误"; }
  systemctl reload nginx 2>/dev/null || systemctl start nginx
  ok "nginx 已重载"
}

firewall_hint() {
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    step "防火墙（ufw 已启用）"
    for r in "22/tcp" "80/tcp" "443/tcp" "7881/tcp" "3478/tcp" "3478/udp" "49160:49200/udp" "50000:50100/udp"; do
      ufw allow "$r" >/dev/null 2>&1 || true
    done
    ok "已放行必要端口"
  else
    step "防火墙"
    warn "未检测到启用的 ufw（或由云厂商安全组管理）"
    dim "请在云控制台安全组放行以下端口："
    dim "  TCP 22, 80, 443, 7881, 3478"
    dim "  UDP 3478, 49160-49200, 50000-50100"
  fi
}

# ---------------------------------------------------------------- 启动
start_stack() {
  step "启动容器"
  cd "$INSTALL_DIR"
  docker compose pull -q >/tmp/compose-pull.log 2>&1 || { tail -20 /tmp/compose-pull.log; die "镜像拉取失败"; }
  docker compose up -d >/tmp/compose-up.log 2>&1 || { tail -30 /tmp/compose-up.log; die "容器启动失败"; }

  dim "等待 Synapse 健康（首次启动要跑数据库迁移）"
  local i
  for i in $(seq 1 60); do
    if curl -fsS --max-time 3 http://127.0.0.1:9108/health >/dev/null 2>&1; then
      ok "Synapse 已就绪（${i}0s 内）"
      return 0
    fi
    sleep 5
  done
  docker compose logs --tail=30 synapse
  if docker compose logs --tail=80 synapse 2>/dev/null | grep -q "password authentication failed"; then
    warn "数据库密码不匹配，通常是 data/postgres 里残留了上一次的密码"
    warn "修复：docker compose down && rm -rf $INSTALL_DIR/data/postgres，然后重新运行"
  fi
  die "Synapse 5 分钟内未就绪"
}

create_admin() {
  step "创建管理员"
  cd "$INSTALL_DIR"
  if docker compose exec -T synapse register_new_matrix_user -c /data/homeserver.yaml \
       -a -u "$ADMIN_USER" -p "$ADMIN_PASS" http://localhost:8008 >/tmp/reg.log 2>&1; then
    ok "管理员 $ADMIN_USER 已创建"
  elif grep -qi "already taken" /tmp/reg.log; then
    warn "用户 $ADMIN_USER 已存在，跳过"
  else
    tail -5 /tmp/reg.log
    warn "创建管理员失败（可稍后手动执行，见 README）"
  fi
}

# ---------------------------------------------------------------- 自检
verify() {
  step "自检"
  local fail=0

  if [[ $PANEL_MODE != standalone ]]; then
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:9108/health || true)
    [[ $code == 200 ]] && ok "Synapse 健康（本机 200）" || { warn "Synapse 健康检查 $code"; fail=1; }
    warn "网站由 1Panel 托管，HTTP 检查跳过（建完站点后再验）"
    return $fail
  fi

  check() { # check 描述 url [期望码]
    local desc=$1 url=$2 want=${3:-200} code
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 --resolve "$(printf '%s' "$url" | awk -F/ '{print $3}'):443:$PUBLIC_IP" "$url" || true)
    if [[ $code == "$want" ]]; then ok "$desc ($code)"; else warn "$desc 期望 $want 实际 $code"; fail=1; fi
  }

  check "Element 网页"        "https://$WEB_FQDN/" 200
  check "客户端发现"          "https://$WEB_FQDN/.well-known/matrix/client" 200
  check "联邦发现"            "https://$WEB_FQDN/.well-known/matrix/server" 200
  check "Matrix API"          "https://$API_FQDN/_matrix/client/versions" 200
  check "管理后台鉴权"        "https://$ADMIN_FQDN/" 401

  if (( ! SKIP_RTC )); then
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 \
      --resolve "$API_FQDN:443:$PUBLIC_IP" "https://$API_FQDN/livekit/jwt/healthz" || true)
    [[ $code == 200 ]] && ok "lk-jwt 健康（200）" || { warn "lk-jwt 健康检查 $code"; fail=1; }
  fi

  return $fail
}

external_check() {
  [[ $PANEL_MODE != standalone ]] && { warn "1Panel 模式：站点建好后请自行访问验证"; return 0; }
  step "公网可达性"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$WEB_FQDN/" || true)
  case "$code" in
    200|302) ok "公网可访问 https://$WEB_FQDN（$code）"; return 0 ;;
  esac
  warn "公网访问 https://$WEB_FQDN 返回 ${code:-超时}"
  warn "服务本身正常（本机自检已通过），问题在云厂商的入站防火墙/安全组"
  dim "请到服务器控制台放行："
  dim "  TCP 80, 443, 7881, 3478"
  dim "  UDP 3478, 49160-49200, 50000-50100"
  dim "（很多 VPS 默认只开 SSH 端口，需要手动放行）"
  return 1
}

summary() {
  local ip=$PUBLIC_IP
  cat <<EOF

${c_grn}部署完成${c_reset}

  Element      https://$WEB_FQDN
  管理后台     https://$ADMIN_FQDN
                Basic Auth: $ADMIN_USER / ${ADMIN_PASS:-<你设置的密码>}
                面板内服务器地址: https://$API_FQDN
  Matrix API   https://$API_FQDN
$([[ $SKIP_RTC == 0 ]] && printf '  通话         LiveKit: wss://%s/livekit/sfu\n               TURN: turn:%s\n' "$API_FQDN" "$API_FQDN")

  管理员账号   @$ADMIN_USER:$WEB_FQDN
  安装目录     $INSTALL_DIR
  配置备份     $INSTALL_DIR/nginx  （站点配置副本）

  常用命令
    cd $INSTALL_DIR
    docker compose ps
    docker compose logs -f synapse
    docker compose exec synapse register_new_matrix_user -c /data/homeserver.yaml -a -u <用户> http://localhost:8008

  云安全组需放行
    TCP 22, 80, 443, 7881, 3478
    UDP 3478, 49160-49200, 50000-50100
EOF
  [[ -n $ip ]] && printf '\n  服务器公网 IP: %s\n' "$ip"
  printf '\n'
}

# ---------------------------------------------------------------- 主流程
main() {
  parse_args "$@"

  printf '\n%sMatrix 全栈部署%s v%s\n' "$c_blue" "$c_reset" "$SCRIPT_VERSION"

  preflight

  step "基本参数"
  if [[ -z $DOMAIN ]]; then
    if (( NON_INTERACTIVE )); then die "非交互模式必须指定 --domain"; fi
    ask DOMAIN "主域名（如 example.com）" ""
    [[ -n $DOMAIN ]] || die "域名不能为空"
  fi
  DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%%/}"
  [[ $DOMAIN =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || die "域名格式不正确: $DOMAIN"

  ask WEB_HOST "网页前缀（用户 ID 会用这个）" "$WEB_HOST"
  [[ $WEB_HOST =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "前缀只能是小写字母、数字、连字符"

  local api_def="${WEB_HOST}api" admin_def="${WEB_HOST}ad"
  API_HOST=${API_HOST:-$api_def}
  ADMIN_HOST=${ADMIN_HOST:-$admin_def}
  ask API_HOST "API 前缀" "$API_HOST"
  ask ADMIN_HOST "管理后台前缀" "$ADMIN_HOST"

  WEB_FQDN="$WEB_HOST.$DOMAIN"
  API_FQDN="$API_HOST.$DOMAIN"
  ADMIN_FQDN="$ADMIN_HOST.$DOMAIN"

  dim "网页 $WEB_FQDN"
  dim "接口 $API_FQDN"
  dim "后台 $ADMIN_FQDN"

  step "可选设置（全部回车即用默认）"
  ask BRAND "站点名称 / 品牌" "$BRAND"
  ask MAX_UPLOAD_SIZE "单文件上传上限（100M/500M/2G/10G，0=不限）" "$MAX_UPLOAD_SIZE"

  ask FEDERATION "联邦模式 closed/whitelist/open" "$FEDERATION"
  case $FEDERATION in
    closed|whitelist|open) ;;
    *) die "联邦模式只能是 closed / whitelist / open" ;;
  esac
  if [[ $FEDERATION == whitelist ]]; then
    ask FEDERATION_DOMAINS "允许联邦的域名（逗号分隔，如 a.com,b.com）" "$FEDERATION_DOMAINS"
    [[ -n $FEDERATION_DOMAINS ]] || die "whitelist 模式必须给至少一个域名"
  fi

  yesno ALLOW_REGISTRATION "允许任何人注册" "$ALLOW_REGISTRATION"
  yesno ALLOW_GUESTS "允许游客浏览房间" "$ALLOW_GUESTS"
  ask UI_LANG "默认界面语言（zh_Hans/en）" "$UI_LANG"
  ask UI_THEME "默认主题（light/dark）" "$UI_THEME"

  if [[ $UI_THEME != light && $UI_THEME != dark ]]; then die "主题只能是 light 或 dark"; fi
  if (( ! SKIP_RTC )) && (( ! NON_INTERACTIVE )); then
    yesno _RTC "启用音视频通话（LiveKit + coturn）" "y"
    [[ $_RTC == y ]] || SKIP_RTC=1
  fi

  if [[ -z $ADMIN_USER ]]; then ask ADMIN_USER "管理员用户名" "ostar"; fi
  if [[ -z $ADMIN_PASS ]]; then
    (( NON_INTERACTIVE )) && die "非交互模式必须指定 --admin-pass"
    while [[ -z $ADMIN_PASS ]]; do ask_secret ADMIN_PASS "管理员密码（至少 8 位）"; done
    (( ${#ADMIN_PASS} >= 8 )) || die "密码太短"
  fi
  [[ -n $EMAIL ]] || EMAIL="admin@$DOMAIN"

  # Cloudflare Token：交互模式下必须问，否则后面建记录/签证书都会失败
  if [[ -z $CF_TOKEN ]] && (( ! NON_INTERACTIVE )) && (( ! SKIP_DNS )); then
    step "Cloudflare API Token"
    cat <<'TOKENHELP'
  需要一个能改 DNS 的 Token：
    Cloudflare → 右上头像 → 我的个人资料 → API 令牌 → 创建令牌
    → 模板选「编辑区域 DNS」→ 区域选你的域名 → 创建 → 复制
  权限要求：Zone → DNS → Edit、Zone → Zone → Read
TOKENHELP
    while [[ -z $CF_TOKEN ]]; do
      ask_secret CF_TOKEN "粘贴 Cloudflare API Token（显示为 *）"
      [[ -n $CF_TOKEN ]] || warn "Token 不能为空，再试一次"
    done
    [[ $CF_TOKEN == cfut_* || ${#CF_TOKEN} -ge 20 ]] || warn "这个值看起来不像 Token，先继续（失败会提示）"
  fi

  if [[ -n $PUBLIC_IP_OVERRIDE ]]; then PUBLIC_IP=$PUBLIC_IP_OVERRIDE; else PUBLIC_IP=$(detect_public_ip); fi
  ok "公网 IP $PUBLIC_IP"

  SSL_CERT="/etc/nginx/ssl/matrix/fullchain.pem"
  SSL_KEY="/etc/nginx/ssl/matrix/privkey.pem"
  HTPASSWD="/etc/nginx/ssl/matrix/admin.htpasswd"
  export SSL_CERT SSL_KEY HTPASSWD

  (( DRY_RUN )) || ensure_swap
  (( DRY_RUN )) || ensure_docker

  if (( DRY_RUN )); then
    [[ $PANEL_MODE == auto ]] && PANEL_MODE=standalone
  else
    choose_panel_mode
  fi
  case $CERT_MODE in panel|acme) ;; *) die "未知的 --cert-mode 值: $CERT_MODE（panel|acme）" ;; esac

  case $PANEL_MODE in
    install-1panel) (( DRY_RUN )) || install_1panel ;;
    1panel)         : ;;  # 等配置渲染完再检查并打印清单
    standalone)     (( DRY_RUN )) || ensure_nginx ;;
    *) die "未知的 --panel 值: $PANEL_MODE（auto|1panel|standalone）" ;;
  esac

  dns_setup
  render_files

  if [[ $PANEL_MODE == 1panel ]] && (( ! DRY_RUN )); then
    panel_prepare
  fi

  if (( DRY_RUN )); then
    step "dry-run 结束"
    ok "配置已渲染到 $INSTALL_DIR（未启动服务）"
    exit 0
  fi

  start_stack

  # 证书模式：standalone 只能用 acme；panel 模式下由面板负责
  if [[ $PANEL_MODE == standalone && $CERT_MODE == panel ]]; then
    CERT_MODE=acme
  fi

  if [[ $CERT_MODE == acme ]]; then
    issue_cert
  else
    step "证书"
    ok "证书由 1Panel 管理，跳过 acme.sh 签发"
    dim "按上面的步骤在面板里申请即可，续期全自动"
  fi

  if [[ $PANEL_MODE == standalone ]]; then
    setup_nginx
  fi
  firewall_hint
  create_admin

  local vfail=0
  verify || vfail=1
  external_check || true

  summary
  if (( vfail )); then
    die "本机自检有未通过项，请查看上面的警告"
  fi
}

main "$@"
