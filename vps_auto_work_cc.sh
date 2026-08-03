#!/usr/bin/env bash
#
# vps_auto_work_cc.sh — Ubuntu VPS 初始化脚本（主要适配 20.04 / 22.04 / 24.04）
# 公开分发: https://github.com/alpha302/vps-auto
# 功能：zsh美化 / swap / docker / pip / java8 / golang / masscan&nmap
#       / 终端美化 & 主机名 / 去除登录提示 / clash / 卸载国内云监控
#       / 安全工具 sectools 套件（EASM skill 对齐，见 -sectools-check）
#       / SSH 远程登录 -ssh（密码+公钥，含 Cursor 连接指引 UTF-8 输出）
#
# 用法：
#   sudo bash vps_auto_work_cc.sh -all          # 全部执行
#   sudo bash vps_auto_work_cc.sh -h            # 帮助（不触发地区检测）
#   sudo bash vps_auto_work_cc.sh -region cn   # 手动设为国内镜像
#   sudo bash vps_auto_work_cc.sh -region auto # 重新自动检测
#
set -uo pipefail

# ───────────────────────── 基础变量 ─────────────────────────
SCRIPT_VERSION="1.5.3"
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/vps_init.log"
REGION_CONFIG="/etc/vps_init.conf"
UPDATE_MANIFEST_URL="https://raw.githubusercontent.com/alpha302/vps-auto/main/version.json"
UPDATE_CONFIG="/etc/vps_auto/update.conf"
UPDATE_BASE_RAW="https://raw.githubusercontent.com/alpha302/vps-auto/main"
DEFAULT_SCRIPT_PATH="/root/.1/vps_auto_work_cc.sh"
DEFAULT_INSTALL_DIR="/root/.1"
DEFAULT_INSTALL_TOOLS_PATH="${DEFAULT_INSTALL_DIR}/install-tools.sh"
DEFAULT_INSTALL_SH_PATH="${DEFAULT_INSTALL_DIR}/install.sh"
ZSHRC="${HOME}/.zshrc"
[ "$(id -u)" -eq 0 ] && ZSHRC="/root/.zshrc"
IS_CN=""              # yes=国内镜像 / no=海外官方源
REGION_COUNTRY=""     # IP 地理国家码
REGION_SOURCE=""      # auto / manual

C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YEL='\033[0;33m'; C_BLUE='\033[0;34m'; C_NC='\033[0m'

log()   { echo -e "${C_BLUE}[INFO]${C_NC} $*" | tee -a "$LOG_FILE"; }
ok()    { echo -e "${C_GREEN}[OK]${C_NC} $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${C_YEL}[WARN]${C_NC} $*" | tee -a "$LOG_FILE"; }
err()   { echo -e "${C_RED}[ERROR]${C_NC} $*" | tee -a "$LOG_FILE"; }
# 供命令替换 $(func) 使用：仅 stderr 输出，避免污染 stdout 返回值
log_err()  { echo -e "${C_BLUE}[INFO]${C_NC} $*" | tee -a "$LOG_FILE" >&2; }
warn_err() { echo -e "${C_YEL}[WARN]${C_NC} $*" | tee -a "$LOG_FILE" >&2; }
err_err()  { echo -e "${C_RED}[ERROR]${C_NC} $*" | tee -a "$LOG_FILE" >&2; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 或 sudo 运行本脚本"
    exit 1
  fi
}

check_ubuntu() {
  if [ ! -f /etc/os-release ]; then
    warn "无法识别系统版本，脚本主要面向 Ubuntu"
    return 0
  fi
  # shellcheck source=/dev/null
  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ]; then
    warn "当前系统: ${PRETTY_NAME:-未知}，脚本针对 Ubuntu 优化，部分步骤可能不适用"
  else
    log "系统: ${PRETTY_NAME}"
    case "${VERSION_ID:-}" in
      20.04|22.04|24.04|24.10) ;;
      *)
        warn "当前 Ubuntu ${VERSION_ID:-未知} 未经充分测试，推荐 20.04 / 22.04 / 24.04"
        ;;
    esac
  fi
}

# 解析 Ubuntu 代号（Docker apt 源等）；22.04=jammy, 24.04=noble
get_ubuntu_codename() {
  if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    if [ -n "${VERSION_CODENAME:-}" ]; then
      echo "$VERSION_CODENAME"
      return 0
    fi
    case "${VERSION_ID:-}" in
      24.04|24.10) echo noble; return 0 ;;
      22.04)       echo jammy; return 0 ;;
      20.04)       echo focal; return 0 ;;
    esac
    [ -n "${UBUNTU_CODENAME:-}" ] && echo "$UBUNTU_CODENAME"
  fi
}

docker_ce_installed() {
  dpkg -l docker-ce 2>/dev/null | awk '$1=="ii"{found=1} END{exit !found}'
}

# Ubuntu 22/24 云镜像常预装 docker.io，与 docker-ce 冲突（官方安装前须移除）
remove_conflicting_docker_packages() {
  log "清理与 docker-ce 冲突的旧包（docker.io / podman-docker / 旧 containerd 等）..."
  systemctl stop docker docker.io containerd 2>/dev/null || true
  apt-get remove -y docker docker-engine docker.io docker-doc docker-compose docker-compose-v2 \
    podman-docker containerd runc 2>>"$LOG_FILE" || true
  apt-get autoremove -y 2>>"$LOG_FILE" || true
}

# 长时间任务进度展示（后台执行 + 终端 spinner，避免 apt/wget 静默卡住）
run_with_spinner() {
  local desc="$1"
  shift
  log "${desc} ..."
  local exit_file
  exit_file=$(mktemp /tmp/vps_init_exit.XXXXXX)
  (
    "$@"
    echo $? > "$exit_file"
  ) >> "$LOG_FILE" 2>&1 &
  local pid=$!
  local frames=('|' '/' '-' '\')
  local i=0 start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    local elapsed=$(( SECONDS - start ))
    printf "\r${C_BLUE}[运行中]${C_NC} %s %s (已 ${elapsed}s，日志: ${LOG_FILE})   " "$desc" "${frames[$((i % 4))]}"
    sleep 0.4
    i=$((i + 1))
  done
  wait "$pid" 2>/dev/null || true
  local exit_code=1 elapsed=$(( SECONDS - start ))
  [ -f "$exit_file" ] && exit_code=$(cat "$exit_file")
  rm -f "$exit_file"
  if [ "$exit_code" -eq 0 ]; then
    printf "\r${C_GREEN}[完成]${C_NC} %s (${elapsed}s)                              \n" "$desc"
  else
    printf "\r${C_RED}[失败]${C_NC} %s (退出码 ${exit_code}，详见 ${LOG_FILE})           \n" "$desc"
  fi
  return "$exit_code"
}

# 下载 GEO/二进制时禁用 shell 代理变量（clash on 设置的 http_proxy 会让 curl 走 7890 并立刻失败）
run_without_proxy() {
  env -u http_proxy -u https_proxy -u all_proxy \
      -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY "$@"
}

# 等待 dpkg/apt 锁释放（cloud-init / unattended-upgrades 常长时间占用）
wait_for_apt_lock() {
  local timeout="${1:-1800}" waited=0
  local locks=(
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/lib/apt/lists/lock
    /var/cache/apt/archives/lock
  )
  while [ "$waited" -lt "$timeout" ]; do
    local busy=0
    # 仅看真实 apt/dpkg；勿用 pgrep 匹配 unattended-upgr（comm 截断会误伤常驻的 shutdown）
    if pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -x dpkg >/dev/null; then
      busy=1
    else
      local f
      for f in "${locks[@]}"; do
        if [ -e "$f" ] && fuser "$f" >/dev/null 2>&1; then
          busy=1
          break
        fi
      done
    fi
    if [ "$busy" -eq 0 ]; then
      [ "$waited" -gt 0 ] && ok "apt/dpkg 锁已释放（等待 ${waited}s）"
      return 0
    fi
    if [ $((waited % 30)) -eq 0 ]; then
      local holder
      holder=$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null | tr -s ' ' | sed 's/^ //')
      warn "等待 apt/dpkg 锁释放… 已 ${waited}s${holder:+（PID: ${holder}）}"
    fi
    sleep 5
    waited=$((waited + 5))
  done
  err "等待 apt/dpkg 锁超时（${timeout}s），请检查: ps aux | grep -E 'apt|dpkg'"
  return 1
}

# apt 操作是否因锁冲突失败（检查近期日志）
apt_failed_on_lock() {
  tail -n 40 "$LOG_FILE" 2>/dev/null | grep -qE 'Could not get lock|Unable to acquire the dpkg frontend lock|is another process using it'
}

# 带等待 + 锁冲突重试的 apt-get install（apt_update 在下方覆盖定义，含 docker 源修复）
apt_install() {
  local attempt=1 max_attempt=6
  while [ "$attempt" -le "$max_attempt" ]; do
    wait_for_apt_lock || return 1
    if run_with_spinner "apt-get install: $*" env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; then
      return 0
    fi
    if apt_failed_on_lock && [ "$attempt" -lt "$max_attempt" ]; then
      warn "apt-get install 遇锁冲突，重试 (${attempt}/${max_attempt}): $*"
      sleep $((attempt * 3))
      attempt=$((attempt + 1))
      continue
    fi
    return 1
  done
  return 1
}

# 安装期间暂停自动 apt，避免与本脚本抢 dpkg 锁
pause_background_apt() {
  log "临时暂停 apt-daily / unattended-upgrades，避免抢锁..."
  systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
  # 仅匹配真正的 /usr/bin/unattended-upgrade，避免误伤常驻的 unattended-upgrade-shutdown
  if pgrep -f '/usr/bin/unattended-upgrade( |$)' >/dev/null 2>&1; then
    warn "检测到 unattended-upgrade 正在运行，将等待其释放锁"
  fi
}

resume_background_apt() {
  systemctl start apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl start unattended-upgrades.service 2>/dev/null || true
}

# 需要走 apt 安装/更新的子命令（启用 pause + EXIT 恢复）
needs_apt_guard() {
  case "${1:-}" in
    -h|--help|-region|""|-ssh-check|-time-check|-traffic-check|-update-check|-update|-update-tools|-sectools-check|-sectools-help|-java|-go|-swap|-noproxy)
      return 1 ;;
    *) return 0 ;;
  esac
}

# 修复残留的 Docker apt 源（GPG 空文件会导致全局 apt-get update 退出码 100）
repair_apt_docker_repo() {
  local docker_list="/etc/apt/sources.list.d/docker.list"
  local docker_gpg="/etc/apt/keyrings/docker.gpg"
  [ -f "$docker_list" ] || return 0

  if [ -f "$docker_gpg" ] && [ -s "$docker_gpg" ]; then
    return 0
  fi

  warn "检测到 Docker apt 源 GPG 密钥缺失或为空（会导致 apt-get update 失败）"
  mkdir -p /etc/apt/keyrings
  local gpg_url="https://download.docker.com/linux/ubuntu/gpg"
  [ "$IS_CN" = "yes" ] && gpg_url="https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg"

  if curl -fsSL "$gpg_url" | gpg --batch --yes --dearmor -o "$docker_gpg" 2>>"$LOG_FILE" \
     && [ -s "$docker_gpg" ]; then
    ok "已重新导入 Docker GPG 密钥"
    return 0
  fi

  warn "GPG 密钥导入失败，临时禁用 Docker apt 源: ${docker_list}"
  mv -f "$docker_list" "${docker_list}.disabled.$(date +%s)" 2>>"$LOG_FILE" || rm -f "$docker_list"
}

import_docker_gpg() {
  local gpg_url="$1"
  local docker_gpg="/etc/apt/keyrings/docker.gpg"
  mkdir -p /etc/apt/keyrings
  curl -fsSL "$gpg_url" | gpg --batch --yes --dearmor -o "$docker_gpg" 2>>"$LOG_FILE" \
    || { err "Docker GPG 密钥下载失败: ${gpg_url}"; return 1; }
  if [ ! -s "$docker_gpg" ]; then
    err "Docker GPG 密钥文件为空: ${docker_gpg}"
    rm -f "$docker_gpg"
    return 1
  fi
  ok "Docker GPG 密钥已写入: ${docker_gpg}"
}

apt_update() {
  local attempt=1 max_attempt=6
  repair_apt_docker_repo
  while [ "$attempt" -le "$max_attempt" ]; do
    wait_for_apt_lock || return 1
    if run_with_spinner "apt-get update" env DEBIAN_FRONTEND=noninteractive apt-get update -y; then
      return 0
    fi
    if apt_failed_on_lock && [ "$attempt" -lt "$max_attempt" ]; then
      warn "apt-get update 遇锁冲突，重试 (${attempt}/${max_attempt})..."
      sleep $((attempt * 3))
      attempt=$((attempt + 1))
      continue
    fi
    return 1
  done
  return 1
}
zshrc_append() {
  local marker="$1"
  local content="$2"
  touch "$ZSHRC"
  if ! grep -qF "# >>> ${marker} >>>" "$ZSHRC" 2>/dev/null; then
    {
      echo ""
      echo "# >>> ${marker} >>>"
      echo "$content"
      echo "# <<< ${marker} <<<"
    } >> "$ZSHRC"
    ok "已写入 .zshrc: ${marker}"
  else
    warn ".zshrc 中已存在 ${marker}，跳过"
  fi
}

# 覆盖写入 .zshrc 标记块（用于更新已有 alias/函数）
zshrc_set() {
  local marker="$1"
  local content="$2"
  touch "$ZSHRC"
  if grep -qF "# >>> ${marker} >>>" "$ZSHRC" 2>/dev/null; then
    local tmp
    tmp=$(mktemp)
    awk -v m="$marker" '
      $0 ~ "^# >>> " m " >>>" { skip=1; next }
      skip && /^# <<< / { skip=0; next }
      !skip { print }
    ' "$ZSHRC" > "$tmp"
    mv "$tmp" "$ZSHRC"
  fi
  {
    echo ""
    echo "# >>> ${marker} >>>"
    echo "$content"
    echo "# <<< ${marker} <<<"
  } >> "$ZSHRC"
  ok "已写入 .zshrc: ${marker}"
}

# oh-my-zsh 核心引导：KEEP_ZSHRC=yes 时旧 .zshrc 可能只有 plugins= 行但无 source，主题/高亮均不生效
# zsh-syntax-highlighting 必须位于 plugins 数组末尾
ensure_omz_bootstrap() {
  local omz_home="${HOME}/.oh-my-zsh"
  local omz_plugins="git autojump zsh-autosuggestions zsh-syntax-highlighting"

  touch "$ZSHRC"
  [ ! -d "$omz_home" ] && { warn "未找到 ${omz_home}，跳过 .zshrc 核心修复"; return 1; }

  if grep -qE 'source\s+(\$ZSH|\$\{ZSH\})/oh-my-zsh\.sh' "$ZSHRC" 2>/dev/null; then
    sed -i "s/^plugins=.*/plugins=(${omz_plugins})/" "$ZSHRC"
    sed -i 's/^ZSH_THEME=.*/ZSH_THEME="robbyrussell"/' "$ZSHRC"
    grep -q '^export ZSH=' "$ZSHRC" || sed -i "1i export ZSH=\"${omz_home}\"" "$ZSHRC"
    ok "已校验 oh-my-zsh 核心配置（plugins 顺序已修正）"
    return 0
  fi

  log "检测到 .zshrc 缺少 source oh-my-zsh.sh，正在重建核心块..."
  local tmp extras
  tmp=$(mktemp)
  extras=$(mktemp)

  awk '
    /^# >>> / { inblock=1 }
    inblock { print; if (/^# <<< /) inblock=0; next }
    /^plugins=/ { next }
    /^ZSH_THEME=/ { next }
    /^export ZSH=/ { next }
    /^source .*oh-my-zsh\.sh/ { next }
    { print }
  ' "$ZSHRC" > "$extras"

  cat > "$tmp" <<EOF
export ZSH="${omz_home}"
ZSH_THEME="robbyrussell"
plugins=(${omz_plugins})
source \$ZSH/oh-my-zsh.sh
EOF
  cat "$extras" >> "$tmp"
  mv "$tmp" "$ZSHRC"
  rm -f "$extras"
  ok "已写入 oh-my-zsh 核心块（修复主题/语法高亮不生效问题）"
}

# ───────────────────────── 地区判断 ─────────────────────────
# 方式一：IP 地理位置 —— 港澳台与大陆严格区分（不依赖 GitHub 连通性）
# 方式二：多节点连通性 —— Cloudflare / Debian / Google 等（GitHub 在香港等地常不可用，不作为主判据）
# 缓存：首次判定后可写入 /etc/vps_init.conf，后续运行直接加载，可用 -region 手动覆盖

test_url_http() {
  local url="$1" timeout="${2:-4}"
  local code
  code=$(curl -s --max-time "$timeout" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  echo "$code" | grep -qE "^(200|204|301|302|307|308|404)$"
}

save_region_config() {
  cat > "$REGION_CONFIG" <<EOF
IS_CN=${IS_CN}
REGION_COUNTRY=${REGION_COUNTRY}
REGION_SOURCE=${REGION_SOURCE}
UPDATED_AT=$(date -Iseconds 2>/dev/null || date)
EOF
  chmod 644 "$REGION_CONFIG"
}

load_region_config() {
  if [ -f "$REGION_CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$REGION_CONFIG"
    [ -n "$IS_CN" ]
    return $?
  fi
  return 1
}

detect_region_auto() {
  log "正在判断服务器网络环境（方式一：IP 地理位置）..."
  REGION_COUNTRY=""
  REGION_COUNTRY=$(curl -s --max-time 5 https://ip.sb/geoip 2>/dev/null | grep -oP '"country_code":\s*"\K[A-Z]{2}')
  if [ -z "$REGION_COUNTRY" ]; then
    REGION_COUNTRY=$(curl -s --max-time 5 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]')
  fi
  if [ -z "$REGION_COUNTRY" ]; then
    REGION_COUNTRY=$(curl -s --max-time 5 https://ipapi.co/country/ 2>/dev/null | tr -d '[:space:]')
  fi

  if [ -n "$REGION_COUNTRY" ]; then
    case "$REGION_COUNTRY" in
      CN) ok "地理位置：中国大陆（CN）" ;;
      HK) ok "地理位置：香港（HK，按海外/官方源处理，不依赖 GitHub 连通性）" ;;
      MO|TW) ok "地理位置：${REGION_COUNTRY}（港澳台，按海外/官方源处理）" ;;
      *) ok "地理位置：海外（国家码: ${REGION_COUNTRY}）" ;;
    esac
  else
    warn "IP 地理位置接口均查询失败，将结合连通性综合判断"
  fi

  log "正在判断服务器网络环境（方式二：多节点连通性，非 GitHub 单点）..."
  local can_reach_overseas="no" can_reach_cn="no"
  local overseas_ok="" cn_ok=""

  for url in \
    "https://cloudflare.com/cdn-cgi/trace" \
    "https://deb.debian.org" \
    "https://www.google.com" \
    "https://www.cloudflare.com"; do
    if test_url_http "$url" 4; then
      can_reach_overseas="yes"
      overseas_ok="${overseas_ok} ${url}"
      break
    fi
  done

  for url in \
    "https://mirrors.aliyun.com" \
    "https://pypi.tuna.tsinghua.edu.cn/simple"; do
    if test_url_http "$url" 5; then
      can_reach_cn="yes"
      cn_ok="${cn_ok:+ }${url}"
      break
    fi
  done

  if [ "$can_reach_overseas" = "yes" ]; then
    ok "海外连通性：可达（${overseas_ok# }）"
  else
    warn "海外连通性：主要节点均不可达（含 Cloudflare/Debian/Google，GitHub 未纳入主判据）"
  fi
  if [ "$can_reach_cn" = "yes" ]; then
    ok "国内镜像连通性：可达（${cn_ok# }）"
  fi

  # ───── 综合判定（镜像策略，非政治地理）─────
  # HK/MO/TW：一律按海外，即使 GitHub 不通
  if [ "$REGION_COUNTRY" = "HK" ] || [ "$REGION_COUNTRY" = "MO" ] || [ "$REGION_COUNTRY" = "TW" ]; then
    IS_CN="no"
    ok "综合判定：港澳台 → 使用官方/海外源（GitHub 不通不影响此判定）"
  elif [ "$REGION_COUNTRY" = "CN" ]; then
    if [ "$can_reach_overseas" = "yes" ]; then
      IS_CN="no"
      ok "综合判定：大陆 IP 但可直连海外 → 使用官方源（疑似专线/国际带宽）"
    else
      IS_CN="yes"
      ok "综合判定：大陆 IP 且海外不可达 → 使用国内镜像源"
    fi
  elif [ -n "$REGION_COUNTRY" ]; then
    IS_CN="no"
    ok "综合判定：海外 IP（${REGION_COUNTRY}）→ 使用官方/海外源"
  elif [ "$can_reach_overseas" = "yes" ]; then
    IS_CN="no"
    ok "综合判定：地理未知但可连海外 → 使用官方源"
  elif [ "$can_reach_cn" = "yes" ]; then
    IS_CN="yes"
    warn "综合判定：地理未知、海外不可达、国内镜像可达 → 使用国内镜像"
  else
    IS_CN="yes"
    warn "综合判定：地理与连通性均不确定，保守按国内镜像处理"
  fi
}

prompt_region_confirm() {
  [ ! -t 0 ] && return 0
  echo ""
  echo -e "${C_YEL}── 地区/镜像策略确认 ──${C_NC}"
  echo -e "  当前判定: $([ "$IS_CN" = "yes" ] && echo "国内镜像源" || echo "海外/官方源（含香港/港澳台）")"
  echo -e "  国家码  : ${REGION_COUNTRY:-未知}"
  echo -e "  说明    : 此设置影响 docker/pip/go/java 等下载源；香港等地区建议选「海外/官方源」"
  read -r -p "使用以上判定？[Y/n] 或输入 c=国内 / o=海外: " ans
  case "$ans" in
    c|C|cn|CN) IS_CN="yes"; REGION_SOURCE="manual"; ok "已手动选择：国内镜像" ;;
    o|O|overseas|海外) IS_CN="no"; REGION_SOURCE="manual"; ok "已手动选择：海外/官方源" ;;
    n|N)
      read -r -p "请选择 [c]国内镜像 / [o]海外官方: " pick
      case "$pick" in
        c|C) IS_CN="yes"; REGION_SOURCE="manual" ;;
        *) IS_CN="no"; REGION_SOURCE="manual" ;;
      esac
      ;;
    *) [ -z "$REGION_SOURCE" ] && REGION_SOURCE="auto" ;;
  esac
}

# 参考 vps_auto_work.sh：优先让用户手动指定地区（含香港/港澳台选项）
prompt_region_manual() {
  echo ""
  echo -e "${C_YEL}是否手动指定服务器地区？${C_NC}"
  echo "  1) 中国大陆（使用国内镜像源）"
  echo "  2) 海外/港澳台（含香港 HK，使用官方源）"
  echo "  3) 自动检测（推荐，检测后可再次确认）"
  read -r -p "请选择 [1/2/3]: " region_choice

  case "$region_choice" in
    1)
      IS_CN="yes"
      REGION_SOURCE="manual"
      REGION_COUNTRY="CN(manual)"
      ok "手动设置为: 中国大陆"
      return 0
      ;;
    2)
      IS_CN="no"
      REGION_SOURCE="manual"
      REGION_COUNTRY="OVERSEAS(manual)"
      ok "手动设置为: 海外/港澳台（含香港）"
      return 0
      ;;
    3|"")
      log "开始自动检测..."
      detect_region_auto
      REGION_SOURCE="${REGION_SOURCE:-auto}"
      prompt_region_confirm
      return 0
      ;;
    *)
      warn "无效选择，使用自动检测"
      detect_region_auto
      REGION_SOURCE="${REGION_SOURCE:-auto}"
      prompt_region_confirm
      return 0
      ;;
  esac
}

init_region() {
  local mode="${1:-}"

  if [ "$mode" = "redetect" ]; then
    rm -f "$REGION_CONFIG"
    mode=""
  fi

  # -all 等安装流程：始终交互询问地区，不直接读缓存退出
  if [ "$mode" = "interactive" ]; then
    prompt_region_manual
    save_region_config
    ok "地区设置已保存至 ${REGION_CONFIG}"
    echo -e "${C_YEL}如需修改: sudo bash ${SCRIPT_NAME} -region cn|overseas|auto${C_NC}\n"
    return 0
  fi

  if [ -z "$mode" ] && load_region_config; then
    local label
    label=$([ "$IS_CN" = "yes" ] && echo "国内镜像" || echo "海外/官方源")
    ok "已加载缓存设置: ${label}（国家: ${REGION_COUNTRY:-未知}，来源: ${REGION_SOURCE:-缓存}，配置: ${REGION_CONFIG}）"
    log "重新检测: sudo bash ${SCRIPT_NAME} -region auto  |  手动设置: -region cn|overseas"
    return 0
  fi

  prompt_region_manual
  save_region_config
  ok "地区设置已保存至 ${REGION_CONFIG}"
}

configure_region_cmd() {
  local arg="${1:-}"
  touch "$LOG_FILE"
  case "$arg" in
    cn|CN|yes|国内)
      IS_CN="yes"; REGION_SOURCE="manual"; REGION_COUNTRY="CN(manual)"
      ;;
    overseas|no|oversea|intl|海外|国外)
      IS_CN="no"; REGION_SOURCE="manual"; REGION_COUNTRY="OVERSEAS(manual)"
      ;;
    auto|detect|redetect|"")
      detect_region_auto
      REGION_SOURCE="auto"
      prompt_region_confirm
      ;;
    *)
      err "未知参数: ${arg}"
      err "用法: sudo bash ${SCRIPT_NAME} -region cn|overseas|auto"
      exit 1
      ;;
  esac
  save_region_config
  ok "地区已设置为: $([ "$IS_CN" = "yes" ] && echo "国内镜像" || echo "海外/官方源")"
  exit 0
}

# 兼容旧函数名
detect_region() { init_region "$@"; }

PUBLIC_IP=""
get_public_ip() {
  PUBLIC_IP=$(curl -s --max-time 5 https://ip.sb 2>/dev/null || curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "未知")
}

# ───────────────────────── 1. zsh + oh-my-zsh + 插件 ─────────────────────────
install_zsh() {
  log "===== 开始安装 zsh / oh-my-zsh / 插件 ====="
  apt_update || warn "apt-get update 失败，继续尝试安装"
  apt_install zsh git curl wget autojump || warn "部分依赖安装失败，请检查日志"

  # 设置默认 shell
  local target_user="${SUDO_USER:-root}"
  chsh -s "$(command -v zsh)" "$target_user" 2>>"$LOG_FILE" || warn "chsh 失败，可手动执行: chsh -s \$(which zsh)"
  ok "已将默认 shell 切换为 zsh（用户: ${target_user}，需重新登录生效）"

  # 安装 oh-my-zsh（国内/国外不同源）
  export RUNZSH=no CHSH=no KEEP_ZSHRC=yes
  if [ "$IS_CN" = "yes" ]; then
    log "使用国内 gitee 镜像安装 oh-my-zsh..."
    sh -c "$(curl -fsSL https://gitee.com/mirrors/oh-my-zsh/raw/master/tools/install.sh)" "" --unattended >> "$LOG_FILE" 2>&1 \
      || warn "oh-my-zsh gitee 安装失败，尝试官方源"
  else
    log "使用官方源安装 oh-my-zsh..."
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended >> "$LOG_FILE" 2>&1 \
      || warn "oh-my-zsh 官方源安装失败"
  fi

  local ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  [ "$(id -u)" -eq 0 ] && ZSH_CUSTOM="/root/.oh-my-zsh/custom"

  if [ ! -d "$HOME/.oh-my-zsh" ] && [ ! -d "/root/.oh-my-zsh" ]; then
    err "oh-my-zsh 安装失败，跳过插件安装"
    return 1
  fi

  mkdir -p "${ZSH_CUSTOM}/plugins"
  if [ ! -d "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting" ]; then
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting" >> "$LOG_FILE" 2>&1 \
      || warn "zsh-syntax-highlighting 克隆失败"
  fi
  if [ ! -d "${ZSH_CUSTOM}/plugins/zsh-autosuggestions" ]; then
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git "${ZSH_CUSTOM}/plugins/zsh-autosuggestions" >> "$LOG_FILE" 2>&1 \
      || warn "zsh-autosuggestions 克隆失败"
  fi
  ok "zsh 插件克隆完成"

  ensure_omz_bootstrap

  zshrc_append "autojump" '[ -f /usr/share/autojump/autojump.sh ] && . /usr/share/autojump/autojump.sh'
  zshrc_append "history-opt" $'HISTSIZE=10000\nSAVEHIST=10000\nsetopt share_history\nsetopt hist_ignore_dups'
  zshrc_append "common-alias" $'alias ll="ls -alF"\nalias la="ls -A"\nalias grep="grep --color=auto"\nalias df="df -h"\nalias free="free -h"'

  # 强制开启 256 色终端，并配置彩色 ls / man / less
  zshrc_append "color-term" $'export TERM="xterm-256color"\nexport CLICOLOR=1\n[ -x "$(command -v dircolors)" ] && eval "$(dircolors -b)"'

  zshrc_append "ls-colors" 'export LS_COLORS="di=1;36:ln=1;35:so=32:pi=33:ex=1;32:bd=34;46:cd=34;43:su=30;41:sg=30;46:tw=30;42:ow=30;43"
alias ls="ls --color=auto"'

  # less / man 高亮（避免看 man 手册或 less 翻页是纯白底黑字）
  zshrc_append "less-colors" 'export LESS_TERMCAP_mb=$(printf "\e[1;32m")
export LESS_TERMCAP_md=$(printf "\e[1;36m")
export LESS_TERMCAP_me=$(printf "\e[0m")
export LESS_TERMCAP_se=$(printf "\e[0m")
export LESS_TERMCAP_so=$(printf "\e[01;33m")
export LESS_TERMCAP_ue=$(printf "\e[0m")
export LESS_TERMCAP_us=$(printf "\e[1;4;31m")'

  ok "已启用彩色主题（robbyrussell）/ 彩色 ls / 彩色 man-less"
  ok "zsh 安装与配置完成，重新登录后生效（或执行: zsh）"
}

# ───────────────────────── 2. swap 虚拟内存 ─────────────────────────
get_mem_mb() {
  awk '/MemTotal/ { print int(($2 + 1023) / 1024) }' /proc/meminfo
}

calc_swap_mb() {
  local mem_mb="$1" swap_mb
  if   [ "$mem_mb" -le 2048 ]; then swap_mb=$((mem_mb * 2))
  elif [ "$mem_mb" -le 8192 ]; then swap_mb=$mem_mb
  elif [ "$mem_mb" -le 16384 ]; then swap_mb=$((mem_mb / 2))
  else swap_mb=8192
  fi
  echo $(( (swap_mb + 511) / 512 * 512 ))
}

format_mb_gib() {
  local mb="$1"
  awk -v m="$mb" 'BEGIN { printf "%.1fG", m/1024 }'
}

get_root_avail_mb() {
  df -BM / 2>/dev/null | awk 'NR==2 { gsub(/M/, "", $4); print $4 }'
}

get_swap_total_mb() {
  swapon --show --bytes --noheadings -o SIZE 2>/dev/null \
    | awk '{ s += $1 } END { if (s > 0) print int((s + 1024 * 1024 - 1) / (1024 * 1024)); else print 0 }'
}

create_swapfile_at() {
  local swap_mb="$1"
  local swapfile="$2"

  local avail_mb
  avail_mb=$(get_root_avail_mb)
  if [ -n "$avail_mb" ] && [ "$avail_mb" -lt $((swap_mb + 512)) ]; then
    err "根分区可用空间不足: ${avail_mb}MB，创建 ${swap_mb}MB swap 需至少 $((swap_mb + 512))MB"
    return 1
  fi

  log "创建 swap 文件: ${swapfile}（${swap_mb}MB / $(format_mb_gib "$swap_mb")）"
  if fallocate -l "${swap_mb}M" "$swapfile" 2>>"$LOG_FILE"; then
    :
  else
    warn "fallocate 失败，改用 dd 创建（速度较慢）"
    dd if=/dev/zero of="$swapfile" bs=1M count="$swap_mb" status=progress >> "$LOG_FILE" 2>&1 \
      || { err "dd 创建 swap 文件失败"; return 1; }
  fi

  chmod 600 "$swapfile"
  mkswap "$swapfile" >> "$LOG_FILE" 2>&1 || { err "mkswap 失败"; return 1; }
  swapon "$swapfile" >> "$LOG_FILE" 2>&1 || { err "swapon 失败"; return 1; }

  if ! grep -q "^${swapfile} " /etc/fstab 2>/dev/null; then
    echo "${swapfile} none swap sw 0 0" >> /etc/fstab
  fi

  sysctl -w vm.swappiness=10 >> "$LOG_FILE" 2>&1
  if grep -q "^vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
    sed -i 's/^vm.swappiness.*/vm.swappiness=10/' /etc/sysctl.conf
  else
    echo "vm.swappiness=10" >> /etc/sysctl.conf
  fi
  return 0
}

setup_swap() {
  log "===== 开始配置 swap ====="
  local mem_mb swap_mb swapfile="/swapfile"
  mem_mb=$(get_mem_mb)
  swap_mb=$(calc_swap_mb "$mem_mb")
  log "物理内存: ${mem_mb}MB ($(format_mb_gib "$mem_mb"))，推荐 swap: ${swap_mb}MB ($(format_mb_gib "$swap_mb"))"

  if swapon --show 2>/dev/null | grep -q .; then
    local cur_mb swap_count swap_name swap_type
    cur_mb=$(get_swap_total_mb)
    swap_count=$(swapon --show --noheadings 2>/dev/null | wc -l)
    swap_name=$(swapon --show --noheadings -o NAME 2>/dev/null | head -1)
    swap_type=$(swapon --show --noheadings -o TYPE 2>/dev/null | head -1)

    log "当前 swap: ${cur_mb}MB（$(format_mb_gib "$cur_mb")），设备数: ${swap_count}"
    swapon --show | tee -a "$LOG_FILE"

    local min_ok_mb=$(( swap_mb * 90 / 100 ))
    if [ "$cur_mb" -ge "$min_ok_mb" ]; then
      ok "现有 swap 已满足推荐大小（>= ${min_ok_mb}MB），跳过"
      return 0
    fi

    if [ "$swap_count" -ne 1 ] || [ "$swap_name" != "$swapfile" ] || [ "$swap_type" != "file" ]; then
      warn "现有 swap 明显小于推荐值（${cur_mb}MB < ${swap_mb}MB），但非单一 ${swapfile} 文件型，请手动调整"
      warn "  分区/LVM swap 示例: sudo swapoff -a && 调整分区/LVM 后 mkswap && swapon -a"
      return 0
    fi

    local mem_avail_mb
    mem_avail_mb=$(awk '/MemAvailable/ { print int($2/1024) }' /proc/meminfo)
    warn "现有 ${swapfile}（${cur_mb}MB）小于推荐 ${swap_mb}MB，将重建 swap 文件"
    if [ -n "$mem_avail_mb" ] && [ "$mem_avail_mb" -lt 512 ]; then
      warn "MemAvailable 仅 ${mem_avail_mb}MB，swapoff 期间可能 OOM，建议在低负载时执行"
    fi

    swapoff "$swapfile" >> "$LOG_FILE" 2>&1 || { err "swapoff ${swapfile} 失败"; return 1; }
    rm -f "$swapfile"
    sed -i "\|^${swapfile} |d" /etc/fstab 2>/dev/null || true
    ok "已关闭并删除旧 ${swapfile}"
  fi

  create_swapfile_at "$swap_mb" "$swapfile" || return 1
  ok "swap 创建完成（${swap_mb}MB / $(format_mb_gib "$swap_mb")），已写入 /etc/fstab 实现开机自启"
  free -h | tee -a "$LOG_FILE"
}

# ───────────────────────── 3. docker ─────────────────────────
install_docker() {
  log "===== 开始安装 docker ====="
  local codename need_install=1
  codename=$(get_ubuntu_codename)
  if [ -z "$codename" ]; then
    err "无法识别 Ubuntu 代号（VERSION_CODENAME），无法配置 Docker 官方/镜像 apt 源"
    return 1
  fi
  log "目标 Docker CE 仓库代号: ${codename}（20.04=focal / 22.04=jammy / 24.04=noble）"

  if docker_ce_installed && command -v docker >/dev/null 2>&1; then
    warn "docker-ce 已安装，跳过安装步骤，仅更新 daemon 配置"
    need_install=0
  elif command -v docker >/dev/null 2>&1 || dpkg -l docker.io 2>/dev/null | grep -q '^ii'; then
    warn "检测到 docker.io 或其它非 docker-ce 安装，将卸载后改装官方 docker-ce（Ubuntu 22.04 常见）"
    remove_conflicting_docker_packages
  fi

  if [ "$need_install" -eq 1 ]; then
    remove_conflicting_docker_packages
    apt_update || { err "apt-get update 失败"; return 1; }
    apt_install ca-certificates curl gnupg lsb-release || return 1
    mkdir -p /etc/apt/keyrings

    if [ "$IS_CN" = "yes" ]; then
      log "使用阿里云源安装 docker-ce（${codename}）..."
      import_docker_gpg "https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg" || return 1
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu ${codename} stable" \
        > /etc/apt/sources.list.d/docker.list
    else
      log "使用 Docker 官方源安装 docker-ce（${codename}）..."
      import_docker_gpg "https://download.docker.com/linux/ubuntu/gpg" || return 1
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" \
        > /etc/apt/sources.list.d/docker.list
    fi

    apt_update || return 1
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
      || { err "docker-ce 安装失败（代号 ${codename}），请查看 ${LOG_FILE}"; return 1; }
  fi

  mkdir -p /etc/docker
  local registry_block=""
  if [ "$IS_CN" = "yes" ]; then
    registry_block='"registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://mirror.ccs.tencentyun.com",
    "https://mirror.baidubce.com"
  ],'
  fi

  cat > /etc/docker/daemon.json <<EOF
{
  ${registry_block}
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
EOF

  systemctl daemon-reload
  systemctl enable docker >> "$LOG_FILE" 2>&1
  systemctl restart docker >> "$LOG_FILE" 2>&1

  if command -v docker >/dev/null 2>&1 && systemctl is-active docker >/dev/null 2>&1; then
    ok "docker-ce 安装/配置完成（${codename}，日志单文件上限50m，最多保留3个文件）"
    docker --version | tee -a "$LOG_FILE"
    docker compose version 2>/dev/null | tee -a "$LOG_FILE" || true
  else
    err "docker 服务未正常运行，请检查: journalctl -u docker -n 50"
    return 1
  fi
}

# ───────────────────────── 4. pip 源 ─────────────────────────
setup_pip() {
  log "===== 配置 pip 源 ====="
  apt_install python3-pip python3-venv pipx || warn "pip 相关包安装失败"

  # Ubuntu 24 (PEP 668) 默认禁止系统级 pip install，会报
  # "externally-managed-environment"。VPS 场景下大多是直接用系统 python，
  # 这里在 pip.conf 里统一加 break-system-packages，免得每次都要手敲参数。
  # 注意：这本质是绕过保护，如果项目对依赖隔离有要求，仍建议用 venv/pipx。
  local pip_conf_content_cn="[global]
index-url = https://pypi.tuna.tsinghua.edu.cn/simple
trusted-host = pypi.tuna.tsinghua.edu.cn
break-system-packages = true"

  local pip_conf_content_overseas="[global]
break-system-packages = true"

  write_pip_conf() {
    local dir="$1"
    mkdir -p "$dir"
    if [ "$IS_CN" = "yes" ]; then
      echo "$pip_conf_content_cn" > "${dir}/pip.conf"
    else
      echo "$pip_conf_content_overseas" > "${dir}/pip.conf"
    fi
  }

  # root 自己的配置
  write_pip_conf "/root/.pip"
  # 如果是用 sudo 跑的脚本，普通用户的配置也写一份，避免该用户 pip install 仍然报错
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    write_pip_conf "/home/${SUDO_USER}/.pip"
    chown -R "${SUDO_USER}:${SUDO_USER}" "/home/${SUDO_USER}/.pip"
  fi
  # 系统级也写一份，部分场景（如 root 用 sudo -E 跑子进程）只认 /etc/pip.conf
  mkdir -p /etc
  if [ "$IS_CN" = "yes" ]; then
    echo "$pip_conf_content_cn" > /etc/pip.conf
  else
    echo "$pip_conf_content_overseas" > /etc/pip.conf
  fi

  if [ "$IS_CN" = "yes" ]; then
    ok "判断为【国内】，已设置清华 pip 源，并启用 break-system-packages 绕过 PEP668 限制"
  else
    ok "判断为【海外】服务器，使用官方 pypi 源，已启用 break-system-packages 绕过 PEP668 限制"
  fi
  setup_npm_mirror_cn
  warn "如需严格依赖隔离，建议改用: python3 -m venv venv && ./venv/bin/pip install -r requirements.txt"
}

# npm 国内镜像（install-tools.sh 中 spectral 等 npm 包装需要）
setup_npm_mirror_cn() {
  [ "$IS_CN" = "yes" ] || return 0
  if ! command -v npm >/dev/null 2>&1; then
    log "npm 未安装，跳过 registry 配置（安装 Node.js 后重新 -pip 或 -update-tools）"
    return 0
  fi
  npm config set registry https://registry.npmmirror.com --global >> "$LOG_FILE" 2>&1 \
    && ok "npm registry → registry.npmmirror.com" \
    || warn "npm registry 配置失败"
  mkdir -p /root/.npm
  echo "registry=https://registry.npmmirror.com" > /root/.npmrc
  ok "已写入 /root/.npmrc"
}

# ───────────────────────── 5. 卸载国内云监控 agent ─────────────────────────
remove_cloud_agent() {
  log "===== 卸载常见国内云监控/安全 agent ====="
  # 阿里云部分调用专项函数
  remove_aliyun

  if [ -d /usr/local/qcloud ]; then
    /usr/local/qcloud/stargate/admin/uninstall.sh >> "$LOG_FILE" 2>&1
    /usr/local/qcloud/YunJing/uninst.sh >> "$LOG_FILE" 2>&1
    /usr/local/qcloud/monitor/barad/admin/uninstall.sh >> "$LOG_FILE" 2>&1
    rm -rf /usr/local/qcloud
    ok "已卸载 腾讯云 YunJing/Stargate/Barad 监控"
  fi

  if [ -d /usr/local/hostguard ]; then
    /usr/local/hostguard/uninstall.sh >> "$LOG_FILE" 2>&1
    rm -rf /usr/local/hostguard
    ok "已卸载 华为云 HostGuard"
  fi

  [ -d /opt/bcm-agent ] && {
    systemctl stop bcm-agent >> "$LOG_FILE" 2>&1
    rm -rf /opt/bcm-agent
    ok "已删除 百度云 BCM Agent"
  }

  ok "云监控清理完成（未安装的厂商自动跳过）"
}

# ───────────────────────── 阿里云 ECS 探针/监控 专项清理 ─────────────────────────
# 覆盖阿里云 ECS 上常见的预装组件：
#   1. 云监控 CloudMonitor (argusagent)    — 性能指标上报
#   2. 安骑士 / 云安全中心 Aegis           — 主机安全扫描
#   3. 云助手 ECS Assist                  — 远程命令执行通道
#   4. 系统残留（cron / systemd service / 开机项）
remove_aliyun() {
  log "===== 阿里云 ECS 探针/监控 专项清理 ====="
  local removed=0

  # ── 预扫描：清理前先让用户看清楚装了哪些 ──
  echo ""
  echo -e "${C_BLUE}── 预扫描：检测阿里云组件 ──${C_NC}"
  local found_any=0

  _check_item() {
    local label="$1"; shift
    local detected=0
    for path in "$@"; do [ -e "$path" ] && detected=1 && break; done
    if [ "$detected" -eq 1 ]; then
      echo -e "  ${C_YEL}[检测到]${C_NC} ${label}"
      found_any=1
    else
      echo -e "  ${C_GREEN}[未安装]${C_NC} ${label}"
    fi
  }

  _check_item "云监控 CloudMonitor/ArgusAgent" \
    /usr/local/cloudmonitor /usr/local/argusagent \
    /etc/systemd/system/cloudmonitor.service /etc/systemd/system/CmsGoAgent.service

  _check_item "安骑士/云安全中心 Aegis" \
    /usr/local/aegis /usr/local/aliyundun \
    /etc/systemd/system/aegis.service /etc/init.d/aegis

  _check_item "云助手 ECS Assist" \
    /usr/local/share/aliyun-assist /opt/aliyun/assist \
    /etc/systemd/system/aliyun-assist.service /etc/systemd/system/aliyun-service.service

  _check_item "ilogtail SLS日志采集器" \
    /usr/local/ilogtail /etc/ilogtail \
    /etc/systemd/system/ilogtail.service /etc/init.d/ilogtaild

  # 进程维度扫描
  local running_procs
  running_procs=$(ps aux 2>/dev/null | grep -iE "AliYunDun|AliHips|aegis|cloudmonitor|argus|aliyun-assist|ilogtail" | grep -v grep || true)
  if [ -n "$running_procs" ]; then
    echo -e "  ${C_YEL}[运行中进程]${C_NC}"
    echo "$running_procs" | while read -r line; do
      echo "    $line"
    done
    found_any=1
  fi

  if [ "$found_any" -eq 0 ]; then
    ok "预扫描：未检测到任何阿里云监控组件，服务器可能已是干净状态"
    read -r -p "是否仍然继续执行清理流程？(y/N): " force_clean
    [[ "$force_clean" =~ ^[Yy]$ ]] || { warn "已取消"; return 0; }
  else
    echo ""
    read -r -p "检测到以上组件，确认执行清理？(Y/n): " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && { warn "已取消"; return 0; }
  fi
  echo ""

  # ── 辅助函数：停止服务+删目录，统一处理 ──
  _stop_and_remove() {
    local service_name="$1"
    local install_dir="$2"
    local label="$3"

    # 先用 systemctl 停/禁用
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
      systemctl stop "$service_name" >> "$LOG_FILE" 2>&1
    fi
    systemctl disable "$service_name" >> "$LOG_FILE" 2>&1 || true
    # 删除 systemd unit 文件
    local unit_paths=(
      "/etc/systemd/system/${service_name}.service"
      "/lib/systemd/system/${service_name}.service"
      "/usr/lib/systemd/system/${service_name}.service"
    )
    for p in "${unit_paths[@]}"; do [ -f "$p" ] && rm -f "$p" && ok "  已删除 unit: $p"; done

    # 删除 init.d 脚本
    [ -f "/etc/init.d/${service_name}" ] && {
      "/etc/init.d/${service_name}" stop >> "$LOG_FILE" 2>&1 || true
      update-rc.d "$service_name" remove >> "$LOG_FILE" 2>&1 || true
      rm -f "/etc/init.d/${service_name}"
    }

    # 删除安装目录
    if [ -n "$install_dir" ] && [ -e "$install_dir" ]; then
      rm -rf "$install_dir"
      ok "  已删除目录: $install_dir"
    fi

    ok "【${label}】清理完成"
    removed=$((removed + 1))
  }

  # ─────────────────────────────────────────
  # 1. 云监控 CloudMonitor / Argus Agent
  #    安装路径: /usr/local/cloudmonitor  /usr/local/argusagent
  #    服务名:   cloudmonitor  argusagent  CmsGoAgent
  # ─────────────────────────────────────────
  log "[1/4] 清理 云监控 CloudMonitor / Argus Agent..."
  for svc in cloudmonitor argusagent CmsGoAgent; do
    systemctl stop "$svc" >> "$LOG_FILE" 2>&1 || true
    systemctl disable "$svc" >> "$LOG_FILE" 2>&1 || true
  done

  # 官方卸载脚本（如果还在的话优先用）
  for uninst in \
    /usr/local/cloudmonitor/wrapdriver.sh \
    /usr/local/cloudmonitor/uninstall.sh \
    /usr/local/argusagent/argusagent.sh
  do
    [ -f "$uninst" ] && bash "$uninst" stop >> "$LOG_FILE" 2>&1 || true
  done

  for d in /usr/local/cloudmonitor /usr/local/argusagent /usr/local/cms; do
    [ -d "$d" ] && rm -rf "$d" && ok "  已删除: $d"
  done
  for f in /etc/init.d/cloudmonitor /etc/init.d/argusagent \
            /etc/systemd/system/cloudmonitor.service \
            /etc/systemd/system/CmsGoAgent.service; do
    [ -f "$f" ] && rm -f "$f" && ok "  已删除: $f"
  done
  ok "【云监控】清理完成"

  # ─────────────────────────────────────────
  # 2. 安骑士 / 云安全中心 Aegis (aliyundun / AliYunDun)
  #    安装路径: /usr/local/aegis  /usr/local/aliyundun
  #    进程名:   AliYunDun  AliHips  AliNet  aliyun-service
  #    服务名:   aegis  aliyun  aliyun-service  aliyundun
  # ─────────────────────────────────────────
  log "[2/4] 清理 安骑士 / 云安全中心 Aegis..."

  # 官方卸载脚本（路径历史上有变化，多试几个）
  for uninst in \
    /usr/local/aegis/aegis_quartz/quartz.sh \
    /usr/local/aegis/aliyun_quartz/quartz.sh \
    /usr/local/aegis/aliyun_quartz/aegis_quartz.sh
  do
    [ -f "$uninst" ] && bash "$uninst" stop >> "$LOG_FILE" 2>&1 || true
  done

  # 强杀残留进程
  for proc in AliYunDun AliHips AliNet AliDetect aliyun-service aegis_quartz aegis_cli; do
    pkill -9 -f "$proc" >> "$LOG_FILE" 2>&1 || true
  done

  for svc in aegis aliyun aliyun-service aliyundun; do
    systemctl stop "$svc" >> "$LOG_FILE" 2>&1 || true
    systemctl disable "$svc" >> "$LOG_FILE" 2>&1 || true
    rm -f "/etc/systemd/system/${svc}.service" \
          "/lib/systemd/system/${svc}.service"
    rm -f "/etc/init.d/${svc}"
  done

  for d in /usr/local/aegis /usr/local/aliyundun /usr/sbin/aliyun-service; do
    [ -e "$d" ] && rm -rf "$d" && ok "  已删除: $d"
  done
  ok "【安骑士/Aegis】清理完成"

  # ─────────────────────────────────────────
  # 3. 云助手 ECS Assist (aliyun_assist_service)
  #    这是阿里云远程执行命令的通道，允许控制台下发 shell 命令到机器
  #    安装路径: /usr/local/share/aliyun-assist  /opt/aliyun/assist
  #    服务名:   aliyun-assist  aliyun_assist_service
  # ─────────────────────────────────────────
  log "[3/5] 清理 云助手 ECS Assist..."

  # 官方卸载入口
  for uninst in \
    /usr/local/share/aliyun-assist/*/aliyun-service \
    /opt/aliyun/assist/*/aliyun-service
  do
    # 防止 glob 展开失败时变成字面量路径
    [ -f "$uninst" ] && "$uninst" --uninstall >> "$LOG_FILE" 2>&1 || true
  done

  for svc in aliyun-assist aliyun_assist_service aliyun-service; do
    systemctl stop "$svc" >> "$LOG_FILE" 2>&1 || true
    systemctl disable "$svc" >> "$LOG_FILE" 2>&1 || true
    rm -f "/etc/systemd/system/${svc}.service" \
          "/lib/systemd/system/${svc}.service"
    rm -f "/etc/init.d/${svc}"
  done

  for d in \
    /usr/local/share/aliyun-assist \
    /opt/aliyun/assist \
    /opt/aliyun \
    /var/log/aliyun-assist \
    /tmp/aliyun_assist_service
  do
    [ -d "$d" ] && rm -rf "$d" && ok "  已删除: $d"
  done
  ok "【云助手 ECS Assist】清理完成"

  # ─────────────────────────────────────────
  # 4. ilogtail — SLS 日志服务采集器
  #    阿里云日志服务（Log Service）的采集 agent，负责实时采集日志上传到 SLS
  #    安装路径: /usr/local/ilogtail  /etc/ilogtail
  #    服务名:   ilogtail  ilogtail-auto-v2  ilogtail.service
  #    包名:     logtail（apt/rpm 方式安装时）
  # ─────────────────────────────────────────
  log "[4/5] 清理 ilogtail (SLS 日志采集)..."

  # 官方提供的卸载脚本（logtail 包安装方式）
  if [ -f /etc/init.d/ilogtaild ]; then
    /etc/init.d/ilogtaild stop >> "$LOG_FILE" 2>&1 || true
  fi
  if command -v logtail >/dev/null 2>&1; then
    logtail --stop >> "$LOG_FILE" 2>&1 || true
  fi

  # 尝试通过包管理器卸载
  if dpkg -l logtail 2>/dev/null | grep -q "^ii"; then
    apt-get remove -y --purge logtail >> "$LOG_FILE" 2>&1 \
      && ok "  已通过 apt 卸载 logtail 包"
  fi

  for svc in ilogtail ilogtaild ilogtail-auto-v2; do
    systemctl stop "$svc"    >> "$LOG_FILE" 2>&1 || true
    systemctl disable "$svc" >> "$LOG_FILE" 2>&1 || true
    rm -f "/etc/systemd/system/${svc}.service" \
          "/lib/systemd/system/${svc}.service" \
          "/etc/init.d/${svc}"
  done

  pkill -9 -f "ilogtail" >> "$LOG_FILE" 2>&1 || true

  for d in \
    /usr/local/ilogtail \
    /etc/ilogtail \
    /var/lib/ilogtail \
    /var/log/ilogtail \
    /tmp/ilogtail*
  do
    [ -e "$d" ] && rm -rf "$d" && ok "  已删除: $d"
  done
  ok "【ilogtail SLS采集器】清理完成"

  # ─────────────────────────────────────────
  # 5. 残留清理：cron / rc.local / 系统账号 / 杂项文件
  # ─────────────────────────────────────────
  log "[5/5] 清理 cron 残留 / 系统账号 / 杂项..."

  # 清理 cron 里写入的阿里云相关项
  for cron_file in /etc/cron.d/* /var/spool/cron/crontabs/*; do
    [ -f "$cron_file" ] && grep -qlE "aegis|aliyun|cloudmonitor|argus|ilogtail" "$cron_file" 2>/dev/null && {
      sed -i -E '/aegis|aliyun|cloudmonitor|argus|ilogtail/d' "$cron_file"
      ok "  已清理 cron: $cron_file"
    }
  done

  # rc.local 中的启动项
  if [ -f /etc/rc.local ] && grep -qE "aegis|aliyun|cloudmonitor|argus|ilogtail" /etc/rc.local 2>/dev/null; then
    sed -i -E '/aegis|aliyun|cloudmonitor|argus|ilogtail/d' /etc/rc.local
    ok "  已清理 /etc/rc.local 中的阿里云启动项"
  fi

  # 杂项目录/文件
  for item in \
    /etc/aliyun-assist \
    /var/log/aliyun \
    /var/run/aliyun-service.pid \
    /tmp/.aegis* \
    /tmp/aliyun*
  do
    [ -e "$item" ] && rm -rf "$item" && ok "  已删除残留: $item"
  done

  # reload systemd
  systemctl daemon-reload >> "$LOG_FILE" 2>&1

  # ── 最终状态确认 ──
  echo ""
  echo -e "${C_BLUE}── 清理后进程扫描（应为空）──${C_NC}"
  local remnants
  remnants=$(ps aux 2>/dev/null | grep -iE "aegis|aliyun|cloudmonitor|argus|AliYunDun|ilogtail" | grep -v grep || true)
  if [ -z "$remnants" ]; then
    ok "进程扫描：未发现阿里云相关进程，清理彻底 ✓"
  else
    warn "以下进程仍在运行，可能需要重启服务器才能完全消除:"
    echo "$remnants" | while read -r line; do echo "  ${C_YEL}${line}${C_NC}"; done
  fi

  echo ""
  echo -e "${C_BLUE}── 清理后目录扫描 ──${C_NC}"
  local remnant_dirs=""
  for d in /usr/local/aegis /usr/local/cloudmonitor /usr/local/argusagent \
            /usr/local/share/aliyun-assist /opt/aliyun \
            /usr/local/ilogtail /etc/ilogtail; do
    [ -e "$d" ] && remnant_dirs="${remnant_dirs} $d"
  done
  if [ -z "$remnant_dirs" ]; then
    ok "目录扫描：主要路径已全部清除 ✓"
  else
    warn "以下目录仍存在:${remnant_dirs}"
  fi

  echo ""
  ok "阿里云 ECS 探针/监控 清理完成（共处理 ${removed} 项服务）"
  warn "建议执行 reboot 确认重启后不再自启"
}


# ───────────────────────── 6. java8 ─────────────────────────
# 校验文件是否为有效 gzip/tarball（Oracle 常返回 HTML 登录页但仍写文件）
is_valid_gzip_tarball() {
  local f="$1"
  [ -s "$f" ] || return 1
  # 过小几乎一定是错误页（真实 JDK8u202 ~185MB，Go ~65MB）
  local sz
  sz=$(wc -c < "$f" 2>/dev/null || echo 0)
  [ "$sz" -gt 1048576 ] || return 1
  gzip -t "$f" >/dev/null 2>&1
}

install_java8() {
  log "===== 安装 Java 8 (Oracle JDK8u202) ====="
  local jdk_dir="/usr/local/java"
  local tarball="/tmp/jdk-8u202-linux-x64.tar.gz"
  mkdir -p "$jdk_dir"
  rm -f "$tarball"

  # Oracle 官方归档下载需要接受 license，浏览器是靠一个 cookie 完成的，
  # 命令行用 --header 带上同样的 cookie 即可绕过登录页直接拿到安装包。
  local oracle_url="https://download.oracle.com/otn/java/jdk/8u202-b08/(908c1d6c2cce4be786c8cfde8993f9d9)/jdk-8u202-linux-x64.tar.gz"
  local huawei_url="https://repo.huaweicloud.com/java/jdk/8u202-b08/jdk-8u202-linux-x64.tar.gz"
  local oracle_cookie="Cookie: oraclelicense=accept-securebackup-cookie"
  local ua="User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

  download_java_tarball() {
    local url="$1"
    shift
    log "尝试下载: ${url}"
    if wget -q --timeout=60 --tries=3 "$@" -O "$tarball" "$url" && is_valid_gzip_tarball "$tarball"; then
      ok "JDK 安装包下载成功 ($(du -h "$tarball" | awk '{print $1}'))"
      return 0
    fi
    rm -f "$tarball"
    return 1
  }

  local ok_dl=0
  if [ "$IS_CN" = "yes" ]; then
    log "国内环境优先使用华为云镜像..."
    download_java_tarball "$huawei_url" && ok_dl=1
    [ "$ok_dl" -eq 0 ] && warn "华为云镜像失败，回退 Oracle..." && \
      download_java_tarball "$oracle_url" --header="$oracle_cookie" --header="$ua" && ok_dl=1
  else
    log "海外环境优先 Oracle，失败则回退华为云镜像..."
    download_java_tarball "$oracle_url" --header="$oracle_cookie" --header="$ua" && ok_dl=1
    [ "$ok_dl" -eq 0 ] && warn "Oracle 下载无效（常见原因：需登录/归档下线/返回 HTML），回退华为云..." && \
      download_java_tarball "$huawei_url" && ok_dl=1
  fi

  if [ "$ok_dl" -ne 1 ]; then
    err "JDK 安装包下载失败，跳过 Java 安装"
    err "如自动下载持续失败，可手动访问华为云或 Oracle 归档页："
    err "  ${huawei_url}"
    err "  https://www.oracle.com/java/technologies/javase/javase8u211-later-archive-downloads.html"
    err "下载后放到 ${tarball} 再重新运行 -java"
    return 1
  fi

  rm -rf "${jdk_dir:?}/"*
  tar -xzf "$tarball" -C "$jdk_dir" --strip-components=1 >> "$LOG_FILE" 2>&1
  rm -f "$tarball"

  zshrc_append "java8" "export JAVA_HOME=${jdk_dir}
export PATH=\$JAVA_HOME/bin:\$PATH
export CLASSPATH=.:\$JAVA_HOME/lib/dt.jar:\$JAVA_HOME/lib/tools.jar"

  # 同时写入 /etc/profile.d，保证非 zsh 登录也生效
  cat > /etc/profile.d/java8.sh <<EOF
export JAVA_HOME=${jdk_dir}
export PATH=\$JAVA_HOME/bin:\$PATH
export CLASSPATH=.:\$JAVA_HOME/lib/dt.jar:\$JAVA_HOME/lib/tools.jar
EOF

  if [ -x "${jdk_dir}/bin/java" ]; then
    ok "Java8 安装完成: $(${jdk_dir}/bin/java -version 2>&1 | head -1)"
  else
    err "Java8 解压后未找到可执行文件: ${jdk_dir}/bin/java"
    return 1
  fi
}

# ───────────────────────── 7. golang ─────────────────────────
install_golang() {
  log "===== 安装 Golang ====="
  local go_ver="1.22.5"
  local arch="amd64"
  case "$(uname -m)" in
    aarch64|arm64) arch="arm64" ;;
  esac
  local tarball="/tmp/go${go_ver}.linux-${arch}.tar.gz"

  rm -f "$tarball"
  local go_urls=()
  if [ "$IS_CN" = "yes" ]; then
    log "使用 Golang 中国镜像站下载..."
    go_urls=(
      "https://mirrors.aliyun.com/golang/go${go_ver}.linux-${arch}.tar.gz"
      "https://golang.google.cn/dl/go${go_ver}.linux-${arch}.tar.gz"
      "https://go.dev/dl/go${go_ver}.linux-${arch}.tar.gz"
    )
  else
    log "使用官方源下载（失败则回退国内镜像）..."
    go_urls=(
      "https://go.dev/dl/go${go_ver}.linux-${arch}.tar.gz"
      "https://mirrors.aliyun.com/golang/go${go_ver}.linux-${arch}.tar.gz"
      "https://golang.google.cn/dl/go${go_ver}.linux-${arch}.tar.gz"
    )
  fi

  local u ok_go=0
  for u in "${go_urls[@]}"; do
    log "尝试: ${u}"
    if wget -q --timeout=60 --tries=3 -O "$tarball" "$u" && is_valid_gzip_tarball "$tarball"; then
      ok "Golang 安装包下载成功 ($(du -h "$tarball" | awk '{print $1}'))"
      ok_go=1
      break
    fi
    rm -f "$tarball"
  done

  if [ "$ok_go" -ne 1 ]; then
    err "golang 安装包下载失败"
    return 1
  fi

  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$tarball" >> "$LOG_FILE" 2>&1
  rm -f "$tarball"

  local gopath="$HOME/go"
  [ "$(id -u)" -eq 0 ] && gopath="/root/go"

  zshrc_append "golang" "export PATH=\$PATH:/usr/local/go/bin
export GOPATH=${gopath}
export PATH=\$PATH:\$GOPATH/bin"

  if [ "$IS_CN" = "yes" ]; then
    zshrc_append "goproxy" '# clash off 时的默认 Go 模块源（clash on 会覆盖）
export GOPROXY=https://goproxy.cn,direct
export GOSUMDB=sum.golang.org'
  fi

  cat > /etc/profile.d/golang.sh <<EOF
export PATH=\$PATH:/usr/local/go/bin:${gopath}/bin
export GOPATH=${gopath}
EOF

  ok "Golang ${go_ver} 安装完成: $(/usr/local/go/bin/go version 2>/dev/null)"
}

# ───────────────────────── apt 国内镜像（Ubuntu 22/24 官方源检测与替换）─────────────────────────
apt_uses_official_ubuntu_mirror() {
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    if grep -qE 'https?://(archive|security|ports)\.ubuntu\.com' "$f" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

apply_apt_mirror_aliyun() {
  local codename ts
  codename="$(get_ubuntu_codename 2>/dev/null || true)"
  [ -n "$codename" ] || { warn "无法识别 Ubuntu 代号，跳过 apt 源替换"; return 1; }

  ts=$(date +%Y%m%d%H%M%S)
  if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    cp -a /etc/apt/sources.list.d/ubuntu.sources "/etc/apt/sources.list.d/ubuntu.sources.bak.${ts}"
    sed -i \
      -e 's|http://archive.ubuntu.com/ubuntu/|http://mirrors.aliyun.com/ubuntu/|g' \
      -e 's|http://security.ubuntu.com/ubuntu/|http://mirrors.aliyun.com/ubuntu/|g' \
      -e 's|https://archive.ubuntu.com/ubuntu/|http://mirrors.aliyun.com/ubuntu/|g' \
      -e 's|https://security.ubuntu.com/ubuntu/|http://mirrors.aliyun.com/ubuntu/|g' \
      /etc/apt/sources.list.d/ubuntu.sources
    ok "已切换 DEB822 源 → 阿里云（${codename}，备份 *.bak.${ts}）"
    return 0
  fi

  if [ -f /etc/apt/sources.list ]; then
    cp -a /etc/apt/sources.list "/etc/apt/sources.list.bak.${ts}"
    sed -i \
      -e 's|http://archive.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu|g' \
      -e 's|http://security.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu|g' \
      -e 's|http://ports.ubuntu.com/ubuntu-ports|http://mirrors.aliyun.com/ubuntu-ports|g' \
      -e 's|https://archive.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu|g' \
      -e 's|https://security.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu|g' \
      /etc/apt/sources.list
    ok "已切换 sources.list → 阿里云（${codename}，备份 *.bak.${ts}）"
    return 0
  fi

  warn "未找到 sources.list / ubuntu.sources，跳过 apt 源替换"
  return 1
}

maybe_setup_apt_mirror_cn() {
  [ "$IS_CN" = "yes" ] || return 0
  if apt_uses_official_ubuntu_mirror; then
    log "国内环境且检测到 Ubuntu 官方 apt 源，替换为阿里云镜像..."
    apply_apt_mirror_aliyun || return 1
    apt_update || warn "切换镜像后 apt-get update 失败"
  else
    log "apt 源已为国内/云厂商镜像或非 Ubuntu 官方，跳过替换"
  fi
}

# ───────────────────────── 8. masscan / nmap ─────────────────────────
install_scanners() {
  log "===== 安装 masscan / nmap ====="
  if command -v masscan >/dev/null 2>&1 && command -v nmap >/dev/null 2>&1 && sectools_should_skip; then
    ok "masscan / nmap 已安装，跳过: $(masscan --version 2>&1 | head -1) | $(nmap --version 2>&1 | head -1)"
    return 0
  fi
  apt_update || warn "apt-get update 失败"
  apt_install masscan nmap \
    && ok "masscan / nmap 安装完成: $(masscan --version 2>&1 | head -1) | $(nmap --version 2>&1 | head -1)" \
    || err "masscan / nmap 安装失败，请检查日志"
}

# ───────────────────────── 9. 终端美化 / 主机名 / 登录信息精简 ─────────────────────────
beautify_terminal() {
  log "===== 终端美化 & 系统优化 ====="

  # 主机名（交互）
  read -r -p "是否需要修改主机名？(y/N): " chg_host
  if [[ "$chg_host" =~ ^[Yy]$ ]]; then
    read -r -p "请输入新的主机名: " new_hostname
    if [ -n "$new_hostname" ]; then
      hostnamectl set-hostname "$new_hostname"
      ok "主机名已修改为: ${new_hostname}（部分场景需重新登录生效）"
    fi
  else
    warn "跳过主机名修改"
  fi

  # 登录 MOTD：仅写入 /etc/motd 一行公网 IP（安装时获取一次，不动态查询）
  if [ -d /etc/update-motd.d ]; then
    for f in /etc/update-motd.d/*; do
      [ -f "$f" ] && chmod -x "$f" 2>/dev/null || true
    done
    rm -f /etc/update-motd.d/99-public-ip
    ok "已禁用 Ubuntu 动态 MOTD 脚本"
  fi

  if [ -f /etc/pam.d/sshd ]; then
    # 只显示静态 /etc/motd，不加载 /run/motd.dynamic
    sed -i -E 's/^(session\s+optional\s+pam_motd\.so\s+motd=\/run\/motd\.dynamic)/# \1/' /etc/pam.d/sshd
    sed -i -E 's/^#\s*(session\s+optional\s+pam_motd\.so\s+noupdate)/\1/' /etc/pam.d/sshd
    if ! grep -qE '^session\s+optional\s+pam_motd\.so\s+noupdate' /etc/pam.d/sshd; then
      sed -i '/^@include common-session/a session    optional     pam_motd.so noupdate' /etc/pam.d/sshd
    fi
    ok "已启用 pam_motd（仅显示 /etc/motd）"
  fi

  if [ -f /etc/ssh/sshd_config ]; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)
    if grep -qE '^\s*PrintLastLog' /etc/ssh/sshd_config; then
      sed -i -E 's/^\s*PrintLastLog.*/PrintLastLog no/' /etc/ssh/sshd_config
    else
      echo "PrintLastLog no" >> /etc/ssh/sshd_config
    fi
    if grep -qE '^\s*PrintMotd' /etc/ssh/sshd_config; then
      sed -i -E 's/^\s*PrintMotd.*/PrintMotd yes/' /etc/ssh/sshd_config
    else
      echo "PrintMotd yes" >> /etc/ssh/sshd_config
    fi
    ok "已设置 PrintLastLog no / PrintMotd yes"
    systemctl restart ssh >> "$LOG_FILE" 2>&1 || systemctl restart sshd >> "$LOG_FILE" 2>&1
  fi

  get_public_ip
  echo "公网IP: ${PUBLIC_IP}" > /etc/motd
  ok "已写入 /etc/motd（公网IP: ${PUBLIC_IP}）"
  log "如需手动修改: nano /etc/motd"

  ok "终端美化与登录信息精简完成"
}

# ───────────────────────── CNVD 众测 OpenVPN（HTTP/HTTPS 策略路由 + 可选全流量）─────────────────────────
# 参考: https://zc.cnvd.org.cn/news/helpList#newsType_21
CNVD_VPN_CONFIG_URL="http://zc.cnvd.org.cn/fileupload/file/vpnconfig.zip"
CNVD_VPN_SERVER="120.202.175.142"

# 安装时写入 CNVD VPN 账号（交互 / 参数 / 环境变量）
prompt_cnvd_vpn_auth() {
  local auth_file="$1"
  local arg_user="${2:-}"
  local arg_pass="${3:-}"
  local vpn_user="" vpn_pass=""

  if [ -n "$arg_user" ] && [ -n "$arg_pass" ]; then
    vpn_user="$arg_user"
    vpn_pass="$arg_pass"
  elif [ -n "${CNVD_VPN_USER:-}" ] && [ -n "${CNVD_VPN_PASS:-}" ]; then
    vpn_user="$CNVD_VPN_USER"
    vpn_pass="$CNVD_VPN_PASS"
  elif [ -f "$auth_file" ] && ! grep -qE '^(#|your_vpn_)' "$auth_file" 2>/dev/null; then
    local existing_user
    existing_user="$(grep -v '^#' "$auth_file" | sed -n '1p')"
    if [ -n "$existing_user" ] && [ -t 0 ]; then
      read -r -p "已有 CNVD VPN 账号 (${existing_user})，是否重新输入？[y/N]: " reauth
      case "$reauth" in
        y|Y|yes|YES) ;;
        *) ok "保留已有 CNVD VPN 账号: ${existing_user}"; return 0 ;;
      esac
    elif [ -n "$existing_user" ]; then
      ok "保留已有 CNVD VPN 账号: ${existing_user}"
      return 0
    fi
  fi

  if [ -z "$vpn_user" ]; then
    if [ ! -t 0 ]; then
      warn "非交互模式：请使用 -cnvd-vpn 用户 密码，或设置 CNVD_VPN_USER/CNVD_VPN_PASS，或稍后 cnvdvpn auth"
      cat > "$auth_file" <<'EOF'
# 请替换为项目详情页底部的 VPN 账号（删除本行注释，保留两行）
your_vpn_username
your_vpn_password
EOF
      chmod 600 "$auth_file"
      return 0
    fi
    echo ""
    echo -e "${C_YEL}── CNVD 众测 VPN 账号（项目详情页底部）──${C_NC}"
    read -r -p "VPN 用户名: " vpn_user
    if [ -z "$vpn_user" ]; then
      warn "未输入用户名，跳过写入账号文件"
      return 1
    fi
    read -r -s -p "VPN 密码: " vpn_pass
    echo ""
    if [ -z "$vpn_pass" ]; then
      warn "未输入密码，跳过写入账号文件"
      return 1
    fi
  fi

  umask 077
  printf '%s\n%s\n' "$vpn_user" "$vpn_pass" > "$auth_file"
  chmod 600 "$auth_file"
  ok "已写入 CNVD VPN 账号: ${auth_file}（用户: ${vpn_user}）"
}

# 将 vpnconfig.zip 中的 ca.crt 导入系统信任库（curl 经 VPN 访问 HTTPS 必需）
install_cnvd_vpn_ca_trust() {
  local ca_src="${1:-/etc/openvpn/cnvd/ca.crt}"
  local ca_dst="/usr/local/share/ca-certificates/cnvd-vpn.crt"
  [ -f "$ca_src" ] || { warn "缺少 ${ca_src}，跳过 CA 导入"; return 1; }
  apt_install ca-certificates >/dev/null 2>&1 || true
  cp "$ca_src" "$ca_dst"
  chmod 644 "$ca_dst"
  if update-ca-certificates 2>>"$LOG_FILE"; then
    ok "CNVD CA 已导入系统信任库: ${ca_dst}（无需 Firefox 单独导入 CA）"
  else
    warn "update-ca-certificates 失败，请手动: cp ${ca_src} ${ca_dst} && update-ca-certificates"
    return 1
  fi
}

install_cnvd_vpn() {
  log "===== 安装 CNVD 众测 OpenVPN（渗透全隧道 + SSH/Web 保护）====="
  local vpn_dir="/etc/openvpn/cnvd"
  local auth_file="/root/.cnvd-vpn.auth"
  local pentest_conf="${vpn_dir}/cnvd-pentest.ovpn"
  local tunnel_up="${vpn_dir}/cnvd-tunnel-up.sh"
  local tunnel_down="${vpn_dir}/cnvd-tunnel-down.sh"
  local tmp_zip="/tmp/cnvd-vpnconfig.zip"

  apt_install openvpn unzip curl iptables iproute2 ca-certificates || return 1
  mkdir -p "$vpn_dir"
  chmod 755 "$vpn_dir"

  log "下载官方配置: ${CNVD_VPN_CONFIG_URL}"
  if ! curl -fsSL -o "$tmp_zip" "$CNVD_VPN_CONFIG_URL"; then
    err "下载 vpnconfig.zip 失败"
    return 1
  fi
  unzip -qo "$tmp_zip" -d "$vpn_dir"
  rm -f "$tmp_zip"
  [ -f "${vpn_dir}/cnvd.ovpn" ] || { err "缺少 cnvd.ovpn"; return 1; }
  [ -f "${vpn_dir}/ca.crt" ] || warn "vpnconfig.zip 未包含 ca.crt，HTTPS 经 VPN 可能证书校验失败"

  install_cnvd_vpn_ca_trust "${vpn_dir}/ca.crt"

  sed -i '/^redirect-gateway/d; /^# CyberStrikeAI/d; /^dhcp-option DNS/d; /^script-security/d; /^up /d; /^down /d; /^auth-user-pass/d' \
    "${vpn_dir}/cnvd.ovpn" 2>/dev/null || true

  cat > "$tunnel_up" <<'TUNNEL_UP_EOF'
#!/bin/bash
# cnvd-tunnel-up.sh — 全隧道：渗透/HTTP/HTTPS 走 VPN；SSH(22)/Web(8081) 回复走 eth0
CNVD_SERVER="120.202.175.142"
MARK=0x2

while ip rule del to "$CNVD_SERVER" lookup main priority 49 2>/dev/null; do :; done
ip rule add to "$CNVD_SERVER" lookup main priority 49 2>/dev/null || true

PHYS_DEV="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
PHYS_DEV="${PHYS_DEV:-eth0}"
GW_HOST="$(ip -4 route show default 2>/dev/null | awk '/default/{print $3; exit}')"
PUB_IP="$(ip -4 -o addr show dev "$PHYS_DEV" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"

RT_TABLES="/etc/iproute2/rt_tables"
# 101 为 SSH/管理专用表；清理旧版 100 cnvd/mgmt 冲突行
sed -i '/^100 cnvd$/d; /^100 mgmt$/d' "$RT_TABLES" 2>/dev/null || true
grep -q '^101 mgmt$' "$RT_TABLES" 2>/dev/null || echo "101 mgmt" >> "$RT_TABLES"
ip route flush table 101 2>/dev/null || true
if [ -n "$GW_HOST" ]; then
  ip route add default via "$GW_HOST" dev "$PHYS_DEV" table 101 2>/dev/null || true
  ip route add "${GW_HOST}/32" dev "$PHYS_DEV" table 101 2>/dev/null || true
  ip route add "${GW_HOST}/32" dev "$PHYS_DEV" 2>/dev/null || true
fi
[ -n "$PUB_IP" ] && ip route add "${PUB_IP}/32" dev "$PHYS_DEV" table 101 2>/dev/null || true
ip -4 route show scope link dev "$PHYS_DEV" 2>/dev/null | awk '/proto kernel/ {print $1}' | while read -r net; do
  case "$net" in */32) continue ;; esac
  ip route add "$net" dev "$PHYS_DEV" table 101 2>/dev/null || true
  ip route add "$net" dev "$PHYS_DEV" 2>/dev/null || true
done

# 清理旧版规则（避免重复/错误 table）
while ip rule del fwmark ${MARK} lookup main priority 50 2>/dev/null; do :; done
while ip rule del fwmark ${MARK} lookup cnvd priority 50 2>/dev/null; do :; done
while ip rule del fwmark ${MARK} lookup mgmt priority 50 2>/dev/null; do :; done
while ip rule del fwmark ${MARK} lookup 101 priority 50 2>/dev/null; do :; done
while ip rule del iif "$PHYS_DEV" lookup mgmt priority 45 2>/dev/null; do :; done
while ip rule del iif "$PHYS_DEV" lookup cnvd priority 45 2>/dev/null; do :; done
while ip rule del iif "$PHYS_DEV" lookup 101 priority 45 2>/dev/null; do :; done

iptables -t mangle -D PREROUTING -i "$PHYS_DEV" -m conntrack --ctstate NEW -j CONNMARK --set-mark ${MARK} 2>/dev/null || true
iptables -t mangle -A PREROUTING -i "$PHYS_DEV" -m conntrack --ctstate NEW -j CONNMARK --set-mark ${MARK}
for port in 22 8081; do
  iptables -t mangle -D INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW,ESTABLISHED -j CONNMARK --set-mark ${MARK} 2>/dev/null || true
  iptables -t mangle -A INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW,ESTABLISHED -j CONNMARK --set-mark ${MARK}
done
iptables -t mangle -D OUTPUT -m connmark --mark ${MARK} -j MARK --set-mark ${MARK} 2>/dev/null || true
iptables -t mangle -A OUTPUT -m connmark --mark ${MARK} -j MARK --set-mark ${MARK}

ip rule add iif "$PHYS_DEV" lookup 101 priority 45 2>/dev/null || true
ip rule add fwmark ${MARK} lookup 101 priority 50 2>/dev/null || true

logger -t cnvd-tunnel "全隧道已启用 phys=${PHYS_DEV} gw=${GW_HOST:-?} pub=${PUB_IP:-?} table=101"
exit 0
TUNNEL_UP_EOF

  cat > "$tunnel_down" <<'TUNNEL_DOWN_EOF'
#!/bin/bash
CNVD_SERVER="120.202.175.142"
MARK=0x2
PHYS_DEV="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
PHYS_DEV="${PHYS_DEV:-eth0}"

while ip rule del to "$CNVD_SERVER" lookup main priority 49 2>/dev/null; do :; done
while ip rule del fwmark ${MARK} lookup main priority 50 2>/dev/null; do :; done
while ip rule del fwmark ${MARK} lookup cnvd priority 50 2>/dev/null; do :; done
while ip rule del fwmark ${MARK} lookup mgmt priority 50 2>/dev/null; do :; done
while ip rule del fwmark ${MARK} lookup 101 priority 50 2>/dev/null; do :; done
while ip rule del iif "$PHYS_DEV" lookup mgmt priority 45 2>/dev/null; do :; done
while ip rule del iif "$PHYS_DEV" lookup cnvd priority 45 2>/dev/null; do :; done
while ip rule del iif "$PHYS_DEV" lookup 101 priority 45 2>/dev/null; do :; done

iptables -t mangle -D PREROUTING -i "$PHYS_DEV" -m conntrack --ctstate NEW -j CONNMARK --set-mark ${MARK} 2>/dev/null || true
for port in 22 8081; do
  while iptables -t mangle -D INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW,ESTABLISHED -j CONNMARK --set-mark ${MARK} 2>/dev/null; do :; done
done
while iptables -t mangle -D OUTPUT -m connmark --mark ${MARK} -j MARK --set-mark ${MARK} 2>/dev/null; do :; done

iptables -t mangle -D OUTPUT -j CNVD_WEB 2>/dev/null || true
iptables -t mangle -F CNVD_WEB 2>/dev/null || true
iptables -t mangle -X CNVD_WEB 2>/dev/null || true
iptables -t mangle -F CNVD_MGMT 2>/dev/null || true
iptables -t mangle -X CNVD_MGMT 2>/dev/null || true

ip route flush table 101 2>/dev/null || true
ip route flush table mgmt 2>/dev/null || true
ip route flush table cnvd 2>/dev/null || true

logger -t cnvd-tunnel "全隧道规则已清理"
exit 0
TUNNEL_DOWN_EOF
  chmod 755 "$tunnel_up" "$tunnel_down"

  sed '/^auth-user-pass/d; /^redirect-gateway/d; /^# CyberStrikeAI/d; /^dhcp-option DNS/d; /^script-security/d; /^up /d; /^down /d' \
    "${vpn_dir}/cnvd.ovpn" > "$pentest_conf"
  cat >> "$pentest_conf" <<EOF

# CyberStrikeAI: 渗透全隧道（HTTP/HTTPS 任意端口走 VPN，SSH+Web 保留 eth0）
redirect-gateway def1
dhcp-option DNS 114.114.114.114
script-security 2
up ${tunnel_up}
down ${tunnel_down}
auth-user-pass ${auth_file}
EOF
  chmod 644 "$pentest_conf" "${vpn_dir}/ca.crt" 2>/dev/null || true

  rm -f "${vpn_dir}/cnvd-safe.ovpn" "${vpn_dir}/cnvd-full.ovpn" \
        "${vpn_dir}/cnvd-up.sh" "${vpn_dir}/cnvd-web-route.sh" "${vpn_dir}/cnvd-web-route-down.sh"

  prompt_cnvd_vpn_auth "$auth_file" "${1:-}" "${2:-}" || warn "账号未配置，可稍后执行: cnvdvpn auth"

  setup_cnvd_vpn_zshrc "$vpn_dir" "$pentest_conf" "$auth_file" "$tunnel_down"
  ok "CNVD VPN 渗透全隧道: ${pentest_conf}"
  ok "  启动: cnvdvpn on（渗透全走 VPN，SSH:22 + Web:8081 保留 eth0）"
  ok "  关闭: cnvdvpn off"
  ok "  验证: cnvdvpn test"
}

setup_cnvd_vpn_zshrc() {
  local vpn_dir="$1"
  local pentest_conf="$2"
  local auth_file="$3"
  local tunnel_down="$4"
  zshrc_set "cnvd-vpn" "# CNVD 众测 OpenVPN — 渗透全隧道 + SSH/Web 保护
export CNVD_VPN_DIR=${vpn_dir}
export CNVD_VPN_CONF=${pentest_conf}
export CNVD_VPN_AUTH=${auth_file}
export CNVD_VPN_TUNNEL_DOWN=${tunnel_down}
export CNVD_VPN_PID=/var/run/cnvd-openvpn.pid
export CNVD_VPN_LOG=/var/log/cnvd-openvpn.log

cnvdvpn() {
  case \"\${1:-}\" in
    on|start|full)
      type clash >/dev/null 2>&1 && clash off 2>/dev/null || true
      unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY 2>/dev/null || true
      if [ ! -f \"\$CNVD_VPN_AUTH\" ] || grep -qE '^(#|your_vpn_)' \"\$CNVD_VPN_AUTH\" 2>/dev/null; then
        echo \"[cnvdvpn] 请先编辑 \$CNVD_VPN_AUTH 或安装时传入账号\"
        echo \"[cnvdvpn] 执行: cnvdvpn auth\"
        return 1
      fi
      chmod 600 \"\$CNVD_VPN_AUTH\"
      if [ -f \"\$CNVD_VPN_PID\" ] && kill -0 \"\$(cat \"\$CNVD_VPN_PID\")\" 2>/dev/null; then
        echo \"[cnvdvpn] 已在运行 pid=\$(cat \"\$CNVD_VPN_PID\")，先执行 cnvdvpn off\"
        return 0
      fi
      sudo openvpn --config \"\$CNVD_VPN_CONF\" --daemon --log \"\$CNVD_VPN_LOG\" --writepid \"\$CNVD_VPN_PID\"
      sleep 4
      echo \"[cnvdvpn] 已启动：渗透/HTTP/HTTPS 全走 VPN，SSH(22)+Web(8081) 保留 eth0\"
      cnvdvpn status
      ;;
    off|stop)
      if [ -f \"\$CNVD_VPN_PID\" ]; then
        sudo kill \"\$(cat \"\$CNVD_VPN_PID\")\" 2>/dev/null || true
        sudo rm -f \"\$CNVD_VPN_PID\"
      fi
      sudo pkill -f 'openvpn.*cnvd-pentest.ovpn' 2>/dev/null || true
      sudo pkill -f 'openvpn.*cnvd-safe.ovpn' 2>/dev/null || true
      sudo pkill -f 'openvpn.*cnvd-full.ovpn' 2>/dev/null || true
      sudo \"\$CNVD_VPN_TUNNEL_DOWN\" 2>/dev/null || true
      echo \"[cnvdvpn] OFF\"
      ;;
    status)
      if [ -f \"\$CNVD_VPN_PID\" ] && kill -0 \"\$(cat \"\$CNVD_VPN_PID\")\" 2>/dev/null; then
        echo \"[cnvdvpn] ON  pid=\$(cat \"\$CNVD_VPN_PID\")\"
        ip -4 route show 2>/dev/null | grep -E '0.0.0.0/1|128.0.0.0/1|default' | head -5
        ip rule list 2>/dev/null | grep -E '101|120.202|fwmark|iif eth0' || true
        ip route show table 101 2>/dev/null || true
        ip -4 addr show 2>/dev/null | grep -E 'tap|tun' || true
      else
        echo \"[cnvdvpn] OFF\"
      fi
      ;;
    test)
      echo \"[cnvdvpn] 出口 IP:\"
      curl -fsSL --max-time 15 ip.sb 2>/dev/null || curl -fsSL --max-time 15 ifconfig.me 2>/dev/null || echo \"curl 失败\"
      echo
      echo \"[cnvdvpn] CNVD HTTPS:\"
      curl -fsSIL --max-time 15 https://zc.cnvd.org.cn/ 2>/dev/null | head -5 || echo \"curl 失败\"
      ;;
    log)
      sudo tail -n 50 -f \"\$CNVD_VPN_LOG\"
      ;;
    auth)
      \${EDITOR:-nano} \"\$CNVD_VPN_AUTH\"
      chmod 600 \"\$CNVD_VPN_AUTH\"
      ;;
    *)
      echo \"用法: cnvdvpn {on|off|status|test|log|auth}\"
      echo \"  on     渗透全隧道 + SSH/Web 保护（推荐）\"
      echo \"  off    断开 VPN 并清理规则\"
      echo \"  test   验证出口 IP 与 CNVD 连通\"
      ;;
  esac
}
alias cnvd-vpn-on='cnvdvpn on'
alias cnvd-vpn-off='cnvdvpn off'"
}

# ───────────────────────── Bugbox OpenVPN（与 cnvdvpn 同级，独立服务端）─────────────────────────
BUGBOX_VPN_SERVER="123.57.208.95"
BUGBOX_VPN_PORT="1192"

prompt_bugbox_vpn_auth() {
  local auth_file="$1"
  local arg_user="${2:-}"
  local arg_pass="${3:-}"
  local vpn_user="" vpn_pass=""

  if [ -n "$arg_user" ] && [ -n "$arg_pass" ]; then
    vpn_user="$arg_user"
    vpn_pass="$arg_pass"
  elif [ -n "${BUGBOX_VPN_USER:-}" ] && [ -n "${BUGBOX_VPN_PASS:-}" ]; then
    vpn_user="$BUGBOX_VPN_USER"
    vpn_pass="$BUGBOX_VPN_PASS"
  elif [ -f "$auth_file" ] && ! grep -qE '^(#|your_vpn_)' "$auth_file" 2>/dev/null; then
    local existing_user
    existing_user="$(grep -v '^#' "$auth_file" | sed -n '1p')"
    if [ -n "$existing_user" ] && [ -t 0 ]; then
      read -r -p "已有 Bugbox VPN 账号 (${existing_user})，是否重新输入？[y/N]: " reauth
      case "$reauth" in
        y|Y|yes|YES) ;;
        *) ok "保留已有 Bugbox VPN 账号: ${existing_user}"; return 0 ;;
      esac
    elif [ -n "$existing_user" ]; then
      ok "保留已有 Bugbox VPN 账号: ${existing_user}"
      return 0
    fi
  fi

  if [ -z "$vpn_user" ]; then
    if [ ! -t 0 ]; then
      warn "非交互模式：请使用 -bugbox-vpn 用户 密码，或设置 BUGBOX_VPN_USER/BUGBOX_VPN_PASS，或稍后 bugboxvpn auth"
      cat > "$auth_file" <<'EOF'
# 请替换为项目详情页底部的 VPN 账号（删除本行注释，保留两行）
your_vpn_username
your_vpn_password
EOF
      chmod 600 "$auth_file"
      return 0
    fi
    echo ""
    echo -e "${C_YEL}── Bugbox 众测 VPN 账号（项目详情页底部）──${C_NC}"
    read -r -p "VPN 用户名: " vpn_user
    if [ -z "$vpn_user" ]; then
      warn "未输入用户名，跳过写入账号文件"
      return 1
    fi
    read -r -s -p "VPN 密码: " vpn_pass
    echo ""
    if [ -z "$vpn_pass" ]; then
      warn "未输入密码，跳过写入账号文件"
      return 1
    fi
  fi

  umask 077
  printf '%s\n%s\n' "$vpn_user" "$vpn_pass" > "$auth_file"
  chmod 600 "$auth_file"
  ok "已写入 Bugbox VPN 账号: ${auth_file}（用户: ${vpn_user}）"
}

install_bugbox_vpn_ca_trust() {
  local ca_src="${1:-/etc/openvpn/bugbox/ca.crt}"
  local ca_dst="/usr/local/share/ca-certificates/bugbox-vpn.crt"
  local proxy_ca_src="${BUGBOX_VPN_PROXY_CA:-${HOME}/.1/bugbox.crt}"
  [ -f "$ca_src" ] || { warn "缺少 ${ca_src}，跳过 CA 导入"; return 1; }
  apt_install ca-certificates >/dev/null 2>&1 || true
  cp "$ca_src" "$ca_dst"
  chmod 644 "$ca_dst"
  # HTTPS 经 VPN 代理时由 rot.proxy 签发证书，需单独导入（与 OpenVPN 隧道 CA 不同）
  if [ -f "$proxy_ca_src" ]; then
    cp "$proxy_ca_src" /usr/local/share/ca-certificates/bugbox-proxy.crt
    chmod 644 /usr/local/share/ca-certificates/bugbox-proxy.crt
    ok "Bugbox HTTPS 代理 CA 已准备: ${proxy_ca_src}（rot.proxy）"
  else
    warn "未找到 ${proxy_ca_src}，HTTPS 经 VPN 可能证书校验失败"
  fi
  if update-ca-certificates 2>>"$LOG_FILE"; then
    ok "Bugbox CA 已导入系统信任库: ${ca_dst}"
  else
    warn "update-ca-certificates 失败，请手动: cp ${ca_src} ${ca_dst} && update-ca-certificates"
    return 1
  fi
}

install_bugbox_vpn() {
  log "===== 安装 Bugbox OpenVPN（渗透全隧道 + SSH/Web 保护）====="
  local vpn_dir="/etc/openvpn/bugbox"
  local auth_file="/root/.bugbox-vpn.auth"
  local pentest_conf="${vpn_dir}/bugbox-pentest.ovpn"
  local tunnel_up="${vpn_dir}/bugbox-tunnel-up.sh"
  local tunnel_down="${vpn_dir}/bugbox-tunnel-down.sh"
  local ovpn_src="${BUGBOX_VPN_OVPN:-${HOME}/.1/client.ovpn}"

  apt_install openvpn curl iptables iproute2 ca-certificates || return 1
  mkdir -p "$vpn_dir"
  chmod 755 "$vpn_dir"

  [ -f "$ovpn_src" ] || { err "缺少 Bugbox 客户端配置: ${ovpn_src}（请上传 client.ovpn）"; return 1; }

  awk '/<ca>/,/<\/ca>/ { if ($0 !~ /^<ca>$/ && $0 !~ /^<\/ca>$/) print }' "$ovpn_src" > "${vpn_dir}/ca.crt"
  [ -s "${vpn_dir}/ca.crt" ] || { err "无法从 ${ovpn_src} 提取 CA 证书"; return 1; }
  chmod 644 "${vpn_dir}/ca.crt"
  install_bugbox_vpn_ca_trust "${vpn_dir}/ca.crt"

  sed '/^auth-user-pass/d; /^redirect-gateway/d; /^# CyberStrikeAI/d; /^dhcp-option DNS/d; /^script-security/d; /^up /d; /^down /d' \
    "$ovpn_src" > "$pentest_conf"

  # OpenVPN 2.6+ 需显式声明 data-ciphers，否则无法协商 AES-128-CBC
  if ! grep -q '^data-ciphers ' "$pentest_conf" 2>/dev/null; then
    sed -i '/^cipher /a data-ciphers AES-128-CBC\ndata-ciphers-fallback AES-128-CBC' "$pentest_conf"
  fi

  cat > "$tunnel_up" <<'TUNNEL_UP_EOF'
#!/bin/bash
# bugbox-tunnel-up.sh — 全隧道：渗透/HTTP/HTTPS 走 VPN；SSH(22)/Web(8081) 回复走 eth0
BUGBOX_SERVER="123.57.208.95"
MARK=0x3

while ip rule del to "$BUGBOX_SERVER" lookup main priority 49 2>/dev/null; do :; done
ip rule add to "$BUGBOX_SERVER" lookup main priority 49 2>/dev/null || true

PHYS_DEV="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
PHYS_DEV="${PHYS_DEV:-eth0}"
GW_HOST="$(ip -4 route show default 2>/dev/null | awk '/default/{print $3; exit}')"
PUB_IP="$(ip -4 -o addr show dev "$PHYS_DEV" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"

RT_TABLES="/etc/iproute2/rt_tables"
sed -i '/^100 bugbox$/d; /^100 mgmt$/d' "$RT_TABLES" 2>/dev/null || true
grep -q '^102 bugbox$' "$RT_TABLES" 2>/dev/null || echo "102 bugbox" >> "$RT_TABLES"
ip route flush table 102 2>/dev/null || true
if [ -n "$GW_HOST" ]; then
  ip route add default via "$GW_HOST" dev "$PHYS_DEV" table 102 2>/dev/null || true
  ip route add "${GW_HOST}/32" dev "$PHYS_DEV" table 102 2>/dev/null || true
  ip route add "${GW_HOST}/32" dev "$PHYS_DEV" 2>/dev/null || true
fi
[ -n "$PUB_IP" ] && ip route add "${PUB_IP}/32" dev "$PHYS_DEV" table 102 2>/dev/null || true
ip -4 route show scope link dev "$PHYS_DEV" 2>/dev/null | awk '/proto kernel/ {print $1}' | while read -r net; do
  case "$net" in */32) continue ;; esac
  ip route add "$net" dev "$PHYS_DEV" table 102 2>/dev/null || true
  ip route add "$net" dev "$PHYS_DEV" 2>/dev/null || true
done

while ip rule del fwmark ${MARK} lookup main priority 50 2>/dev/null; do :; done
while ip rule del fwmark ${MARK} lookup bugbox priority 50 2>/dev/null; do :; done
while ip rule del fwmark ${MARK} lookup 102 priority 50 2>/dev/null; do :; done
while ip rule del iif "$PHYS_DEV" lookup bugbox priority 45 2>/dev/null; do :; done
while ip rule del iif "$PHYS_DEV" lookup 102 priority 45 2>/dev/null; do :; done

iptables -t mangle -D PREROUTING -i "$PHYS_DEV" -m conntrack --ctstate NEW -j CONNMARK --set-mark ${MARK} 2>/dev/null || true
iptables -t mangle -A PREROUTING -i "$PHYS_DEV" -m conntrack --ctstate NEW -j CONNMARK --set-mark ${MARK}
for port in 22 8081; do
  iptables -t mangle -D INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW,ESTABLISHED -j CONNMARK --set-mark ${MARK} 2>/dev/null || true
  iptables -t mangle -A INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW,ESTABLISHED -j CONNMARK --set-mark ${MARK}
done
iptables -t mangle -D OUTPUT -m connmark --mark ${MARK} -j MARK --set-mark ${MARK} 2>/dev/null || true
iptables -t mangle -A OUTPUT -m connmark --mark ${MARK} -j MARK --set-mark ${MARK}

ip rule add iif "$PHYS_DEV" lookup 102 priority 45 2>/dev/null || true
ip rule add fwmark ${MARK} lookup 102 priority 50 2>/dev/null || true

logger -t bugbox-tunnel "全隧道已启用 phys=${PHYS_DEV} gw=${GW_HOST:-?} pub=${PUB_IP:-?} table=102"
exit 0
TUNNEL_UP_EOF

  cat > "$tunnel_down" <<'TUNNEL_DOWN_EOF'
#!/bin/bash
BUGBOX_SERVER="123.57.208.95"
MARK=0x3
PHYS_DEV="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
PHYS_DEV="${PHYS_DEV:-eth0}"

while ip rule del to "$BUGBOX_SERVER" lookup main priority 49 2>/dev/null; do :; done
while ip rule del fwmark ${MARK} lookup main priority 50 2>/dev/null; do :; done
while ip rule del fwmark ${MARK} lookup bugbox priority 50 2>/dev/null; do :; done
while ip rule del fwmark ${MARK} lookup 102 priority 50 2>/dev/null; do :; done
while ip rule del iif "$PHYS_DEV" lookup bugbox priority 45 2>/dev/null; do :; done
while ip rule del iif "$PHYS_DEV" lookup 102 priority 45 2>/dev/null; do :; done

iptables -t mangle -D PREROUTING -i "$PHYS_DEV" -m conntrack --ctstate NEW -j CONNMARK --set-mark ${MARK} 2>/dev/null || true
for port in 22 8081; do
  while iptables -t mangle -D INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW,ESTABLISHED -j CONNMARK --set-mark ${MARK} 2>/dev/null; do :; done
done
while iptables -t mangle -D OUTPUT -m connmark --mark ${MARK} -j MARK --set-mark ${MARK} 2>/dev/null; do :; done

ip route flush table 102 2>/dev/null || true
ip route flush table bugbox 2>/dev/null || true

logger -t bugbox-tunnel "全隧道规则已清理"
exit 0
TUNNEL_DOWN_EOF
  chmod 755 "$tunnel_up" "$tunnel_down"

  cat >> "$pentest_conf" <<EOF

# CyberStrikeAI: 渗透全隧道（HTTP/HTTPS 任意端口走 VPN，SSH+Web 保留 eth0）
redirect-gateway def1
dhcp-option DNS 114.114.114.114
script-security 2
up ${tunnel_up}
down ${tunnel_down}
auth-user-pass ${auth_file}
EOF
  chmod 644 "$pentest_conf"

  prompt_bugbox_vpn_auth "$auth_file" "${1:-}" "${2:-}" || warn "账号未配置，可稍后执行: bugboxvpn auth"

  setup_bugbox_vpn_zshrc "$vpn_dir" "$pentest_conf" "$auth_file" "$tunnel_down"
  ok "Bugbox VPN 渗透全隧道: ${pentest_conf}"
  ok "  服务端: ${BUGBOX_VPN_SERVER}:${BUGBOX_VPN_PORT}（来自 ${ovpn_src}）"
  ok "  启动: bugboxvpn on（渗透全走 VPN，SSH:22 + Web:8081 保留 eth0）"
  ok "  关闭: bugboxvpn off"
  ok "  验证: bugboxvpn test"
}

setup_bugbox_vpn_zshrc() {
  local vpn_dir="$1"
  local pentest_conf="$2"
  local auth_file="$3"
  local tunnel_down="$4"
  zshrc_set "bugbox-vpn" "# Bugbox 众测 OpenVPN — 渗透全隧道 + SSH/Web 保护
export BUGBOX_VPN_DIR=${vpn_dir}
export BUGBOX_VPN_CONF=${pentest_conf}
export BUGBOX_VPN_AUTH=${auth_file}
export BUGBOX_VPN_TUNNEL_DOWN=${tunnel_down}
export BUGBOX_VPN_PID=/var/run/bugbox-openvpn.pid
export BUGBOX_VPN_LOG=/var/log/bugbox-openvpn.log
export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

bugboxvpn() {
  case \"\${1:-}\" in
    on|start|full)
      type clash >/dev/null 2>&1 && clash off 2>/dev/null || true
      type cnvdvpn >/dev/null 2>&1 && cnvdvpn off 2>/dev/null || true
      unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY 2>/dev/null || true
      if [ ! -f \"\$BUGBOX_VPN_AUTH\" ] || grep -qE '^(#|your_vpn_)' \"\$BUGBOX_VPN_AUTH\" 2>/dev/null; then
        echo \"[bugboxvpn] 请先编辑 \$BUGBOX_VPN_AUTH 或安装时传入账号\"
        echo \"[bugboxvpn] 执行: bugboxvpn auth\"
        return 1
      fi
      chmod 600 \"\$BUGBOX_VPN_AUTH\"
      if [ -f \"\$BUGBOX_VPN_PID\" ] && kill -0 \"\$(cat \"\$BUGBOX_VPN_PID\")\" 2>/dev/null; then
        echo \"[bugboxvpn] 已在运行 pid=\$(cat \"\$BUGBOX_VPN_PID\")，先执行 bugboxvpn off\"
        return 0
      fi
      sudo openvpn --config \"\$BUGBOX_VPN_CONF\" --daemon --log \"\$BUGBOX_VPN_LOG\" --writepid \"\$BUGBOX_VPN_PID\"
      sleep 4
      echo \"[bugboxvpn] 已启动：渗透/HTTP/HTTPS 全走 VPN，SSH(22)+Web(8081) 保留 eth0\"
      bugboxvpn status
      ;;
    off|stop)
      if [ -f \"\$BUGBOX_VPN_PID\" ]; then
        sudo kill \"\$(cat \"\$BUGBOX_VPN_PID\")\" 2>/dev/null || true
        sudo rm -f \"\$BUGBOX_VPN_PID\"
      fi
      sudo pkill -f 'openvpn.*bugbox-pentest.ovpn' 2>/dev/null || true
      sudo \"\$BUGBOX_VPN_TUNNEL_DOWN\" 2>/dev/null || true
      echo \"[bugboxvpn] OFF\"
      ;;
    status)
      if [ -f \"\$BUGBOX_VPN_PID\" ] && kill -0 \"\$(cat \"\$BUGBOX_VPN_PID\")\" 2>/dev/null; then
        echo \"[bugboxvpn] ON  pid=\$(cat \"\$BUGBOX_VPN_PID\")\"
        ip -4 route show 2>/dev/null | grep -E '0.0.0.0/1|128.0.0.0/1|default' | head -5
        ip rule list 2>/dev/null | grep -E '102|120.202|fwmark|iif eth0' || true
        ip route show table 102 2>/dev/null || true
        ip -4 addr show 2>/dev/null | grep -E 'tap|tun' || true
      else
        echo \"[bugboxvpn] OFF\"
      fi
      ;;
    test)
      echo \"[bugboxvpn] 出口 IP:\"
      curl -fsSL --max-time 15 ip.sb 2>/dev/null || curl -fsSL --max-time 15 ifconfig.me 2>/dev/null || echo \"curl 失败\"
      echo
      echo \"[bugboxvpn] VPN 服务端连通:\"
      timeout 5 bash -c \"echo >/dev/tcp/${BUGBOX_VPN_SERVER}/${BUGBOX_VPN_PORT}\" 2>/dev/null && echo \"TCP ${BUGBOX_VPN_SERVER}:${BUGBOX_VPN_PORT} OK\" || echo \"TCP 连接失败\"
      ;;
    log)
      sudo tail -n 50 -f \"\$BUGBOX_VPN_LOG\"
      ;;
    auth)
      \${EDITOR:-nano} \"\$BUGBOX_VPN_AUTH\"
      chmod 600 \"\$BUGBOX_VPN_AUTH\"
      ;;
    *)
      echo \"用法: bugboxvpn {on|off|status|test|log|auth}\"
      echo \"  on     渗透全隧道 + SSH/Web 保护（推荐）\"
      echo \"  off    断开 VPN 并清理规则\"
      echo \"  test   验证出口 IP 与 CNVD 连通\"
      ;;
  esac
}
alias bugbox-vpn-on='bugboxvpn on'
alias bugbox-vpn-off='bugboxvpn off'"
}

# ───────────────────────── 腾讯云任务 VPN（证书认证，分流 10.x）─────────────────────────
TASK_VPN_SERVER="106.53.0.169"
TASK_VPN_PORT="9798"

install_task_vpn_ca_trust() {
  local ca_src="${1:-/etc/openvpn/task/ca.crt}"
  local ca_dst="/usr/local/share/ca-certificates/task-vpn.crt"
  [ -f "$ca_src" ] || { warn "缺少 ${ca_src}，跳过 CA 导入"; return 1; }
  apt_install ca-certificates >/dev/null 2>&1 || true
  cp "$ca_src" "$ca_dst"
  chmod 644 "$ca_dst"
  if update-ca-certificates 2>>"$LOG_FILE"; then
    ok "Task VPN CA 已导入系统信任库: ${ca_dst}"
  else
    warn "update-ca-certificates 失败，请手动: cp ${ca_src} ${ca_dst} && update-ca-certificates"
    return 1
  fi
}

install_task_vpn() {
  log "===== 安装腾讯云任务 OpenVPN（证书认证 + 分流 10.x）====="
  local vpn_dir="/etc/openvpn/task"
  local pentest_conf="${vpn_dir}/task-pentest.ovpn"
  local tunnel_up="${vpn_dir}/task-tunnel-up.sh"
  local tunnel_down="${vpn_dir}/task-tunnel-down.sh"
  local ovpn_src="${1:-${TASK_VPN_OVPN:-${HOME}/.1/task_g3oS99An9R5_vpn_config.ovpn}}"

  apt_install openvpn curl iptables iproute2 ca-certificates || return 1
  mkdir -p "$vpn_dir"
  chmod 755 "$vpn_dir"

  [ -f "$ovpn_src" ] || { err "缺少任务 VPN 配置: ${ovpn_src}"; return 1; }

  cp "$ovpn_src" "${vpn_dir}/task-client.ovpn"
  awk '/<ca>/,/<\/ca>/ { if ($0 !~ /^<ca>$/ && $0 !~ /^<\/ca>$/) print }' "$ovpn_src" > "${vpn_dir}/ca.crt"
  [ -s "${vpn_dir}/ca.crt" ] || { err "无法从 ${ovpn_src} 提取 CA 证书"; return 1; }
  chmod 644 "${vpn_dir}/ca.crt"
  install_task_vpn_ca_trust "${vpn_dir}/ca.crt"

  sed '/^redirect-gateway/d; /^# CyberStrikeAI/d; /^dhcp-option DNS/d; /^script-security/d; /^up /d; /^down /d' \
    "$ovpn_src" > "$pentest_conf"

  cat > "$tunnel_up" <<'TUNNEL_UP_EOF'
#!/bin/bash
# task-tunnel-up.sh — 分流 VPN：10.x 走 VPN；SSH(22)/Web(8081) 回复走 eth0
TASK_SERVER="106.53.0.169"
MARK=0x4

while ip rule del to "$TASK_SERVER" lookup main priority 49 2>/dev/null; do :; done
ip rule add to "$TASK_SERVER" lookup main priority 49 2>/dev/null || true

PHYS_DEV="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
PHYS_DEV="${PHYS_DEV:-eth0}"
GW_HOST="$(ip -4 route show default 2>/dev/null | awk '/default/{print $3; exit}')"
PUB_IP="$(ip -4 -o addr show dev "$PHYS_DEV" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"

RT_TABLES="/etc/iproute2/rt_tables"
grep -q '^103 task$' "$RT_TABLES" 2>/dev/null || echo "103 task" >> "$RT_TABLES"
ip route flush table 103 2>/dev/null || true
if [ -n "$GW_HOST" ]; then
  ip route add default via "$GW_HOST" dev "$PHYS_DEV" table 103 2>/dev/null || true
  ip route add "${GW_HOST}/32" dev "$PHYS_DEV" table 103 2>/dev/null || true
  ip route add "${GW_HOST}/32" dev "$PHYS_DEV" 2>/dev/null || true
fi
[ -n "$PUB_IP" ] && ip route add "${PUB_IP}/32" dev "$PHYS_DEV" table 103 2>/dev/null || true
ip -4 route show scope link dev "$PHYS_DEV" 2>/dev/null | awk '/proto kernel/ {print $1}' | while read -r net; do
  case "$net" in */32) continue ;; esac
  ip route add "$net" dev "$PHYS_DEV" table 103 2>/dev/null || true
  ip route add "$net" dev "$PHYS_DEV" 2>/dev/null || true
done

while ip rule del fwmark ${MARK} lookup 103 priority 50 2>/dev/null; do :; done
while ip rule del iif "$PHYS_DEV" lookup 103 priority 45 2>/dev/null; do :; done

iptables -t mangle -D PREROUTING -i "$PHYS_DEV" -m conntrack --ctstate NEW -j CONNMARK --set-mark ${MARK} 2>/dev/null || true
iptables -t mangle -A PREROUTING -i "$PHYS_DEV" -m conntrack --ctstate NEW -j CONNMARK --set-mark ${MARK}
for port in 22 8081; do
  iptables -t mangle -D INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW,ESTABLISHED -j CONNMARK --set-mark ${MARK} 2>/dev/null || true
  iptables -t mangle -A INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW,ESTABLISHED -j CONNMARK --set-mark ${MARK}
done
iptables -t mangle -D OUTPUT -m connmark --mark ${MARK} -j MARK --set-mark ${MARK} 2>/dev/null || true
iptables -t mangle -A OUTPUT -m connmark --mark ${MARK} -j MARK --set-mark ${MARK}

ip rule add iif "$PHYS_DEV" lookup 103 priority 45 2>/dev/null || true
ip rule add fwmark ${MARK} lookup 103 priority 50 2>/dev/null || true

logger -t task-tunnel "分流 VPN 已启用 phys=${PHYS_DEV} gw=${GW_HOST:-?} pub=${PUB_IP:-?} table=103"
exit 0
TUNNEL_UP_EOF

  cat > "$tunnel_down" <<'TUNNEL_DOWN_EOF'
#!/bin/bash
TASK_SERVER="106.53.0.169"
MARK=0x4
PHYS_DEV="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
PHYS_DEV="${PHYS_DEV:-eth0}"

while ip rule del to "$TASK_SERVER" lookup main priority 49 2>/dev/null; do :; done
while ip rule del fwmark ${MARK} lookup 103 priority 50 2>/dev/null; do :; done
while ip rule del iif "$PHYS_DEV" lookup 103 priority 45 2>/dev/null; do :; done

iptables -t mangle -D PREROUTING -i "$PHYS_DEV" -m conntrack --ctstate NEW -j CONNMARK --set-mark ${MARK} 2>/dev/null || true
for port in 22 8081; do
  while iptables -t mangle -D INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW,ESTABLISHED -j CONNMARK --set-mark ${MARK} 2>/dev/null; do :; done
done
while iptables -t mangle -D OUTPUT -m connmark --mark ${MARK} -j MARK --set-mark ${MARK} 2>/dev/null; do :; done

ip route flush table 103 2>/dev/null || true

logger -t task-tunnel "分流 VPN 规则已清理"
exit 0
TUNNEL_DOWN_EOF
  chmod 755 "$tunnel_up" "$tunnel_down"

  cat >> "$pentest_conf" <<EOF

# CyberStrikeAI: 腾讯云分流 VPN（使用服务端推送的 10.x 路由，保留 eth0 公网）
script-security 2
up ${tunnel_up}
down ${tunnel_down}
EOF
  chmod 644 "$pentest_conf"

  setup_task_vpn_zshrc "$vpn_dir" "$pentest_conf" "$tunnel_down"
  ok "Task VPN 分流配置: ${pentest_conf}"
  ok "  服务端: ${TASK_VPN_SERVER}:${TASK_VPN_PORT} UDP（来自 ${ovpn_src}）"
  ok "  启动: taskvpn on（10.x 走 VPN，公网/SSH/Web 保留 eth0）"
  ok "  关闭: taskvpn off"
  ok "  验证: taskvpn test"
}

setup_task_vpn_zshrc() {
  local vpn_dir="$1"
  local pentest_conf="$2"
  local tunnel_down="$3"
  zshrc_set "task-vpn" "# 腾讯云任务 VPN — 证书认证 + 分流 10.x
export TASK_VPN_DIR=${vpn_dir}
export TASK_VPN_CONF=${pentest_conf}
export TASK_VPN_TUNNEL_DOWN=${tunnel_down}
export TASK_VPN_PID=/var/run/task-openvpn.pid
export TASK_VPN_LOG=/var/log/task-openvpn.log
export TASK_VPN_SERVER=${TASK_VPN_SERVER}
export TASK_VPN_PORT=${TASK_VPN_PORT}

taskvpn() {
  case \"\${1:-}\" in
    on|start|full)
      type clash >/dev/null 2>&1 && clash off 2>/dev/null || true
      type cnvdvpn >/dev/null 2>&1 && cnvdvpn off 2>/dev/null || true
      type bugboxvpn >/dev/null 2>&1 && bugboxvpn off 2>/dev/null || true
      unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY 2>/dev/null || true
      if [ -f \"\$TASK_VPN_PID\" ] && kill -0 \"\$(cat \"\$TASK_VPN_PID\")\" 2>/dev/null; then
        echo \"[taskvpn] 已在运行 pid=\$(cat \"\$TASK_VPN_PID\")，先执行 taskvpn off\"
        return 0
      fi
      sudo openvpn --config \"\$TASK_VPN_CONF\" --daemon --log \"\$TASK_VPN_LOG\" --writepid \"\$TASK_VPN_PID\"
      sleep 5
      echo \"[taskvpn] 已启动：腾讯云 VPN UDP \${TASK_VPN_SERVER}:\${TASK_VPN_PORT}（分流 10.x，SSH/Web 保留 eth0）\"
      taskvpn status
      ;;
    off|stop)
      if [ -f \"\$TASK_VPN_PID\" ]; then
        sudo kill \"\$(cat \"\$TASK_VPN_PID\")\" 2>/dev/null || true
        sudo rm -f \"\$TASK_VPN_PID\"
      fi
      sudo pkill -f 'openvpn.*task-pentest.ovpn' 2>/dev/null || true
      sudo \"\$TASK_VPN_TUNNEL_DOWN\" 2>/dev/null || true
      echo \"[taskvpn] OFF\"
      ;;
    status)
      if [ -f \"\$TASK_VPN_PID\" ] && kill -0 \"\$(cat \"\$TASK_VPN_PID\")\" 2>/dev/null; then
        echo \"[taskvpn] ON  pid=\$(cat \"\$TASK_VPN_PID\")\"
        ip -4 route show 2>/dev/null | grep -E '10\\.|tun|default' | head -8
        ip rule list 2>/dev/null | grep -E '103|106.53|fwmark|iif eth0' || true
        ip route show table 103 2>/dev/null || true
        ip -4 addr show 2>/dev/null | grep -E 'tap|tun' || true
      else
        echo \"[taskvpn] OFF\"
      fi
      ;;
    test)
      echo \"[taskvpn] 公网出口 IP:\"
      curl -fsSL --max-time 15 http://ip.sb 2>/dev/null || curl -fsSL --max-time 15 ifconfig.me 2>/dev/null || echo \"curl 失败\"
      echo
      echo \"[taskvpn] VPN 网关:\"
      ping -c 1 -W 2 10.254.0.1 2>/dev/null && echo \"10.254.0.1 OK\" || echo \"10.254.0.1 不可达\"
      ;;
    log)
      sudo tail -n 50 -f \"\$TASK_VPN_LOG\"
      ;;
    *)
      echo \"用法: taskvpn {on|off|status|test|log}\"
      echo \"  配置: \${TASK_VPN_CONF}\"
      ;;
  esac
}
alias task-vpn-on='taskvpn on'
alias task-vpn-off='taskvpn off'"
}

# ───────────────────────── 10. clash（仅海外服务器可选） ─────────────────────────
# 加载地区配置（-clash 单独运行时可能未走 init_region）
load_region_if_needed() {
  if [ -n "$IS_CN" ]; then
    return 0
  fi
  if [ -f "$REGION_CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$REGION_CONFIG"
    log_err "已加载地区设置: $([ "$IS_CN" = "yes" ] && echo "国内镜像" || echo "海外/官方源")"
  fi
}

# GitHub 下载 URL 列表：国内优先加速镜像（mihomo 无官方 Gitee Release，用 GH 代理加速）
github_download_urls() {
  local url="$1"
  local gitclone_url=""
  if [[ "$url" == https://github.com/* ]]; then
    gitclone_url="https://gitclone.com/github.com/${url#https://github.com/}"
  fi
  if [ "$IS_CN" = "yes" ]; then
    printf '%s\n' \
      "https://ghfast.top/${url}" \
      "https://ghproxy.net/${url}" \
      "https://mirror.ghproxy.com/${url}" \
      "${gitclone_url}" \
      "https://hub.njuu.top/${url}" \
      "${url}"
  else
    printf '%s\n' \
      "${url}" \
      "https://ghfast.top/${url}" \
      "https://ghproxy.net/${url}" \
      "${gitclone_url}"
  fi
}

# GitHub API / 文件 GET，多源回退
curl_github() {
  local url="$1"
  local body="" u
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    body=$(run_without_proxy curl -fsSL --max-time 25 "$u" 2>/dev/null) && [ -n "$body" ] && { echo "$body"; return 0; }
  done < <(github_download_urls "$url")
  return 1
}

download_url_with_fallback() {
  local url="$1"
  local dest="$2"
  local timeout="${3:-60}"
  local u
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    log_err "尝试下载: ${u}"
    if run_without_proxy wget -q --show-progress --timeout="$timeout" -t 2 -O "$dest" "$u" >> "$LOG_FILE" 2>&1 && [ -s "$dest" ]; then
      ok "下载成功"
      return 0
    fi
    rm -f "$dest"
    warn_err "下载超时/失败，尝试下一源..."
  done < <(github_download_urls "$url")
  return 1
}

# 检测 mihomo 代理端口是否真正在监听（systemctl active ≠ 代理可用）
is_mihomo_proxy_ready() {
  local port="${1:-$(get_mihomo_proxy_port)}"
  ss -tln 2>/dev/null | grep -q ":${port} " && return 0
  command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$port" 2>/dev/null && return 0
  curl -s --max-time 2 -o /dev/null "http://127.0.0.1:${port}" 2>/dev/null && return 0
  return 1
}

wait_mihomo_proxy_ready() {
  local port="${1:-$(get_mihomo_proxy_port)}"
  local max_wait="${2:-45}"
  local i=0
  while [ "$i" -lt "$max_wait" ]; do
    is_mihomo_proxy_ready "$port" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# 读取 mihomo 代理端口（profile.conf / config.yaml）
get_mihomo_proxy_port() {
  local mihomo_cfg="/etc/mihomo"
  local port="7890"
  if [ -f "${mihomo_cfg}/profile.conf" ]; then
    # shellcheck disable=SC1090
    . "${mihomo_cfg}/profile.conf"
    port="${MIHOMO_PORT:-7890}"
  fi
  if [ -f "${mihomo_cfg}/config.yaml" ]; then
    local p
    p=$(grep -E '^(mixed-port|port):' "${mihomo_cfg}/config.yaml" 2>/dev/null | head -1 | awk '{print $2}')
    [ -n "$p" ] && port="$p"
  fi
  echo "$port"
}

# 确保 mihomo 代理端口可用（缺 GEO 时 mihomo 会卡住且不监听 7890）
ensure_mihomo_running_for_proxy() {
  local mihomo_bin="/usr/local/bin/mihomo"
  local mihomo_cfg="/etc/mihomo"
  local port
  port=$(get_mihomo_proxy_port)

  [ -f "${mihomo_cfg}/config.yaml" ] || return 1
  [ -x "$mihomo_bin" ] || return 1

  if is_mihomo_proxy_ready "$port"; then
    ok "mihomo 代理就绪 127.0.0.1:${port}"
    return 0
  fi

  # 进程在但端口未开：通常卡在下载 MMDB（缺 geoip.dat）
  if systemctl is-active --quiet mihomo 2>/dev/null || pgrep -f "${mihomo_bin} -d ${mihomo_cfg}" >/dev/null 2>&1; then
    warn "mihomo 进程存在但端口 ${port} 未监听（缺少 GEO 数据库时会如此，无法走代理）"
    return 1
  fi

  # 有 GEO 才能正常启动并监听端口
  if [ ! -s "${mihomo_cfg}/geoip.dat" ] || [ ! -s "${mihomo_cfg}/geosite.dat" ] || [ ! -s "${mihomo_cfg}/country.mmdb" ]; then
    warn "GEO/MMDB 未就绪（需 geoip.dat + geosite.dat + country.mmdb），mihomo 无法开启代理端口"
    return 1
  fi

  log "启动 mihomo 以使用本地代理..."
  if systemctl start mihomo >> "$LOG_FILE" 2>&1; then
    if wait_mihomo_proxy_ready "$port" 45; then
      ok "mihomo 已就绪 (127.0.0.1:${port})"
      return 0
    fi
    systemctl stop mihomo >> "$LOG_FILE" 2>&1 || true
  fi

  nohup "$mihomo_bin" -d "$mihomo_cfg" >> "$LOG_FILE" 2>&1 &
  if wait_mihomo_proxy_ready "$port" 30; then
    ok "mihomo 已就绪 (127.0.0.1:${port})"
    return 0
  fi

  warn "mihomo 启动后端口 ${port} 仍未就绪"
  return 1
}

# 通过本地 mihomo 代理下载（HTTP + SOCKS5h，GEO 大文件用长超时）
download_via_local_proxy() {
  local url="$1"
  local dest="$2"
  local port="${3:-$(get_mihomo_proxy_port)}"
  local timeout="${4:-300}"
  local http_proxy="http://127.0.0.1:${port}"
  local socks_proxy="socks5h://127.0.0.1:${port}"

  is_mihomo_proxy_ready "$port" || {
    warn "127.0.0.1:${port} 不可连接，代理不可用"
    return 1
  }

  log "通过 mihomo 代理下载: ${url}"
  rm -f "$dest"

  if run_without_proxy curl -fsSL --max-time "$timeout" -x "$http_proxy" -o "$dest" "$url" >> "$LOG_FILE" 2>&1 && [ -s "$dest" ]; then
    ok "代理下载成功 (HTTP)"
    return 0
  fi
  rm -f "$dest"

  if run_without_proxy curl -fsSL --max-time "$timeout" --proxy "$socks_proxy" -o "$dest" "$url" >> "$LOG_FILE" 2>&1 && [ -s "$dest" ]; then
    ok "代理下载成功 (SOCKS5)"
    return 0
  fi
  rm -f "$dest"

  if run_without_proxy wget -q --show-progress --timeout="$timeout" -t 2 \
    -e use_proxy=yes -e "http_proxy=${http_proxy}" -e "https_proxy=${http_proxy}" \
    -O "$dest" "$url" >> "$LOG_FILE" 2>&1 && [ -s "$dest" ]; then
    ok "代理下载成功 (wget)"
    return 0
  fi

  warn "代理下载失败（详见 ${LOG_FILE}）"
  rm -f "$dest"
  return 1
}

# 镜像多源 → 失败则走 mihomo 本地代理（需端口真正就绪）
download_url_smart() {
  local url="$1"
  local dest="$2"
  local timeout="${3:-60}"
  local mihomo_cfg="/etc/mihomo"

  if download_url_with_fallback "$url" "$dest" "$timeout"; then
    return 0
  fi

  if [ ! -f "${mihomo_cfg}/config.yaml" ]; then
    warn "无 mihomo 配置，无法走代理下载"
    return 1
  fi

  warn "镜像/直连均失败，尝试通过 clash/mihomo 代理下载..."
  if ! ensure_mihomo_running_for_proxy; then
    warn "代理不可用，跳过（常见原因：缺少 geoip.dat 导致 mihomo 未监听 7890）"
    return 1
  fi
  download_via_local_proxy "$url" "$dest" "$(get_mihomo_proxy_port)" "$timeout"
}

# MetaCubeX/meta-rules-dat 国内优先镜像（MMDB/geoip/geosite；无代理可下载）
meta_rules_dat_mirror_urls() {
  local file="$1"
  local gh="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/${file}"
  printf '%s\n' \
    "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/${file}" \
    "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/${file}" \
    "https://hub.keccak.top/MetaCubeX/meta-rules-dat/releases/download/latest/${file}" \
    "https://ghfast.top/${gh}" \
    "https://ghproxy.net/${gh}" \
    "https://mirror.ghproxy.com/${gh}" \
    "${gh}"
}

# mihomo geox-url 国内镜像（内核自动拉 MMDB 时使用，避免直连 GitHub）
mihomo_geox_mirror_urls() {
  echo "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat"
  echo "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"
  echo "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb"
  echo "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/GeoLite2-ASN.mmdb"
}

# GEO / MMDB 大文件专用下载（国内 CDN 优先，长超时；禁用 shell 代理）
download_geo_file() {
  local dest="$1"
  local name
  name=$(basename "$dest")
  local timeout=600

  if [ -n "${http_proxy:-}${HTTP_PROXY:-}${all_proxy:-}${ALL_PROXY:-}" ]; then
    warn "检测到 shell 代理环境变量，GEO/MMDB 下载将绕过代理直连国内镜像"
  fi

  local u
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    log "下载 ${name} ←"
    log "  ${u}"
    log "  单源最长 ${timeout}s，下方显示已用时间..."
    if run_with_spinner "下载 ${name}" run_without_proxy curl -fL \
         --connect-timeout 30 --max-time "$timeout" \
         --retry 2 --retry-delay 5 \
         -o "$dest" "$u"; then
      if [ -s "$dest" ]; then
        ok "${name} 下载成功 ($(du -h "$dest" 2>/dev/null | awk '{print $1}'))"
        return 0
      fi
    fi
    rm -f "$dest"
    warn "${name} 当前源失败，尝试下一镜像..."
  done < <(meta_rules_dat_mirror_urls "$name")
  warn "${name} 所有镜像均失败"
  return 1
}

# 下载 GeoIP / GeoSite / MMDB（必须先于 mihomo 代理端口就绪）
download_geo_databases() {
  local mihomo_cfg="/etc/mihomo"
  local mihomo_bin="/usr/local/bin/mihomo"
  local port
  port=$(get_mihomo_proxy_port)

  if [ -s "${mihomo_cfg}/geoip.dat" ] && [ -s "${mihomo_cfg}/geosite.dat" ] \
     && [ -s "${mihomo_cfg}/country.mmdb" ]; then
    ok "GEO/MMDB 已存在，跳过下载"
    return 0
  fi

  # 缺 GEO/MMDB 时 mihomo 会卡死并尝试直连 GitHub 下载
  if systemctl is-active --quiet mihomo 2>/dev/null || pgrep -f "${mihomo_bin} -d ${mihomo_cfg}" >/dev/null 2>&1; then
    if ! is_mihomo_proxy_ready "$port"; then
      warn "mihomo 运行中但端口 ${port} 未就绪，先停止以便下载 GEO/MMDB..."
      systemctl stop mihomo >> "$LOG_FILE" 2>&1 || true
      pkill -f "${mihomo_bin} -d ${mihomo_cfg}" >> "$LOG_FILE" 2>&1 || true
      sleep 2
    fi
  fi

  local geo_ok=1 f
  for f in geoip.dat geosite.dat country.mmdb; do
    [ -s "${mihomo_cfg}/${f}" ] && continue
    download_geo_file "${mihomo_cfg}/${f}" || geo_ok=0
  done

  if [ "$geo_ok" -eq 1 ]; then
    ok "GEO/MMDB 数据库下载完成（geoip.dat + geosite.dat + country.mmdb）"
  else
    warn "GEO/MMDB 下载不完整（mihomo 需 geoip.dat / geosite.dat / country.mmdb）"
    warn "手动示例: curl -fL -o /etc/mihomo/country.mmdb \\"
    warn "  'https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb'"
  fi

  if [ "$geo_ok" -eq 1 ] && [ -f /etc/systemd/system/mihomo.service ]; then
    systemctl restart mihomo >> "$LOG_FILE" 2>&1 || true
    if wait_mihomo_proxy_ready "$port" 30; then
      ok "mihomo 已重启，代理端口 ${port} 就绪"
    fi
  fi
  return $((1 - geo_ok))
}

# mihomo 固定版本回退（GitHub API 不可达时使用，仅输出 URL 到 stdout）
mihomo_fallback_download_url() {
  local arch="$1"
  local ver="v1.19.27"
  local fname="mihomo-linux-${arch}-v3-go123-${ver}.gz"
  echo "https://github.com/MetaCubeX/mihomo/releases/download/${ver}/${fname}"
}

# 解析 mihomo 最新 Release 中适合当前架构的 .gz 包（stdout 仅输出 URL）
resolve_mihomo_download_url() {
  local arch="$1"
  local api_url="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
  local urls url json

  load_region_if_needed
  if [ "$IS_CN" = "yes" ]; then
    log_err "国内网络 → mihomo 使用 GitHub 加速镜像（无官方 Gitee 包，同 oh-my-zsh 用 gitee、二进制用 GH 代理）"
  else
    log_err "海外/官方源 → mihomo GitHub 直连优先"
  fi

  json=$(curl_github "$api_url") || {
    warn_err "GitHub API 不可达，使用固定版本回退 URL"
    mihomo_fallback_download_url "$arch"
    return 0
  }

  urls=$(echo "$json" \
    | grep -o '"browser_download_url": "[^"]*"' \
    | cut -d'"' -f4 \
    | grep -E "mihomo-linux-${arch}.*\.gz$" \
    | grep -vE '\.(deb|rpm|pkg\.tar\.zst)$')

  # 优先级：v3-go124 > v3-go123 > v3 > v2 > 标准版
  for pat in \
    "mihomo-linux-${arch}-v3-go124-" \
    "mihomo-linux-${arch}-v3-go123-" \
    "mihomo-linux-${arch}-v3-" \
    "mihomo-linux-${arch}-v2-go124-" \
    "mihomo-linux-${arch}-v2-go123-" \
    "mihomo-linux-${arch}-v1-go124-" \
    "mihomo-linux-${arch}-v1\.19\." \
    "mihomo-linux-${arch}-"; do
    url=$(echo "$urls" | grep "$pat" | head -1)
    if [ -n "$url" ]; then
      echo "$url"
      return 0
    fi
  done

  warn_err "Release 中未匹配到 linux-${arch} 包，使用固定版本回退 URL"
  mihomo_fallback_download_url "$arch"
  return 0
}

# 从 URL 或本地路径安装 mihomo 二进制（支持 .gz 或裸二进制）
install_mihomo_binary() {
  local source="$1"
  local mihomo_bin="/usr/local/bin/mihomo"
  local tmp="/tmp/mihomo-dl.$$"

  if [ -z "$source" ]; then
    err "未指定 mihomo 下载地址"
    return 1
  fi

  if [ -f "$source" ]; then
    log "使用本地文件: ${source}"
    cp -f "$source" "$tmp"
  elif [[ "$source" =~ ^https?:// ]]; then
    load_region_if_needed
    download_url_with_fallback "$source" "$tmp" || {
      rm -f "$tmp"
      return 1
    }
  else
    err "无效地址（需为 http(s) URL 或本地文件路径）: ${source}"
    return 1
  fi

  if [ ! -s "$tmp" ]; then
    err "mihomo 文件为空"
    rm -f "$tmp"
    return 1
  fi

  if gzip -t "$tmp" 2>/dev/null; then
    gunzip -f -c "$tmp" > "${mihomo_bin}.new" || { rm -f "$tmp" "${mihomo_bin}.new"; return 1; }
  else
    mv -f "$tmp" "${mihomo_bin}.new"
  fi
  rm -f "$tmp"

  chmod +x "${mihomo_bin}.new"
  if ! "${mihomo_bin}.new" -v >/dev/null 2>&1 && ! "${mihomo_bin}.new" -h >/dev/null 2>&1; then
    err "文件似乎不是有效的 mihomo 二进制，请检查 URL/路径"
    rm -f "${mihomo_bin}.new"
    return 1
  fi

  mv -f "${mihomo_bin}.new" "$mihomo_bin"
  ok "mihomo 安装完成: $($mihomo_bin -v 2>/dev/null | head -1)"
}

# 部署 clash/mihomo 配置文件，并记录来源供后续 -clash 复用（端口写入 MIHOMO_PROXY_PORT）
deploy_mihomo_config() {
  local src="$1"
  local mihomo_cfg="/etc/mihomo"
  local dest="${mihomo_cfg}/config.yaml"
  local profile="${mihomo_cfg}/profile.conf"
  local proxy_port=7890

  MIHOMO_PROXY_PORT=7890
  mkdir -p "$mihomo_cfg"

  if [ -z "$src" ]; then
    err "未指定配置文件路径"
    return 1
  fi

  if [[ "$src" =~ ^https?:// ]]; then
    log "从 URL 下载配置: ${src}"
    wget -q -O "$dest" "$src" || { err "配置下载失败"; return 1; }
  elif [ -f "$src" ]; then
    local abs_src
    abs_src=$(readlink -f "$src" 2>/dev/null || realpath "$src" 2>/dev/null || echo "$src")
    log "部署本地配置: ${abs_src}"
    ln -sf "$abs_src" "$dest"
    src="$abs_src"
  else
    err "配置文件不存在: ${src}"
    return 1
  fi

  if ! grep -qE '^(mixed-port|port|proxies|proxy-groups|rules):' "$dest" 2>/dev/null; then
    warn "文件看起来不像标准 mihomo/clash 配置，请确认格式"
    read -r -p "是否仍然继续？(y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 1
  fi

  proxy_port=$(grep -E '^(mixed-port|port):' "$dest" 2>/dev/null | head -1 | awk '{print $2}')
  proxy_port="${proxy_port:-7890}"

  grep -q "^mixed-port" "$dest" 2>/dev/null || echo "mixed-port: ${proxy_port}" >> "$dest"
  grep -q "^external-controller" "$dest" 2>/dev/null || echo "external-controller: 127.0.0.1:9090" >> "$dest"
  harden_mihomo_config "$dest"

  cat > "$profile" <<EOF
CONFIG_SOURCE=${src}
CONFIG_FILE=${dest}
MIHOMO_PORT=${proxy_port}
UPDATED_AT=$(date -Iseconds 2>/dev/null || date)
EOF
  chmod 644 "$profile" "$dest" 2>/dev/null || true

  ok "配置已部署 → ${dest}"
  ok "配置来源: ${src}（本地文件为软链接，修改源文件后 clash reload 生效）"
  MIHOMO_PROXY_PORT="$proxy_port"
  return 0
}

# VPS 安全加固：禁止公网滥用代理（allow-lan=true 会导致被扫成开放代理，CPU 飙满）
harden_mihomo_config() {
  local dest="${1:-/etc/mihomo/config.yaml}"
  [ -f "$dest" ] || { warn "未找到 mihomo 配置: ${dest}"; return 1; }

  if grep -qE '^allow-lan:' "$dest"; then
    sed -i 's/^allow-lan:.*/allow-lan: false/' "$dest"
  else
    echo "allow-lan: false" >> "$dest"
  fi

  if grep -qE '^bind-address:' "$dest"; then
    sed -i "s/^bind-address:.*/bind-address: '127.0.0.1'/" "$dest"
  else
    echo "bind-address: '127.0.0.1'" >> "$dest"
  fi

  if grep -qE '^log-level:' "$dest"; then
    sed -i 's/^log-level:.*/log-level: warning/' "$dest"
  fi

  ok "mihomo 已加固: allow-lan=false, bind-address=127.0.0.1, log-level=warning"
  inject_mihomo_geox_mirrors "$dest"
  warn "订阅更新后若恢复 allow-lan:true，请重新执行: sudo bash ${SCRIPT_NAME} -clash-harden"
}

# 注入 geox-url 国内镜像，避免 mihomo 启动时直连 GitHub 拉 MMDB
inject_mihomo_geox_mirrors() {
  local dest="$1"
  [ -f "$dest" ] || return 1

  local geoip_m geosite_m mmdb_m asn_m
  mapfile -t _geox < <(mihomo_geox_mirror_urls)
  geoip_m="${_geox[0]:-https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat}"
  geosite_m="${_geox[1]:-https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat}"
  mmdb_m="${_geox[2]:-https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb}"
  asn_m="${_geox[3]:-https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/GeoLite2-ASN.mmdb}"

  if grep -q '^geox-url:' "$dest" 2>/dev/null; then
    sed -i \
      -E "s|^([[:space:]]*geoip:).*|\1 \"${geoip_m}\"|" \
      -E "s|^([[:space:]]*geosite:).*|\1 \"${geosite_m}\"|" \
      -E "s|^([[:space:]]*mmdb:).*|\1 \"${mmdb_m}\"|" \
      -E "s|^([[:space:]]*asn:).*|\1 \"${asn_m}\"|" \
      "$dest" 2>/dev/null || true
    grep -qE '^[[:space:]]*mmdb:' "$dest" || {
      sed -i "/^geox-url:/a\\  mmdb: \"${mmdb_m}\"" "$dest" 2>/dev/null || true
    }
  else
    cat >> "$dest" <<EOF

# vps_auto: geox 国内镜像（MMDB/geoip 无代理可下载）
geodata-mode: true
geox-url:
  geoip: "${geoip_m}"
  geosite: "${geosite_m}"
  mmdb: "${mmdb_m}"
  asn: "${asn_m}"
EOF
  fi
  ok "已配置 geox-url 国内镜像（country.mmdb / geoip / geosite）"
}

setup_clash_zshrc() {
  local port="${1:-7890}"
  zshrc_set "mihomo-proxy" "# Go 模块下载走 GOPROXY（非 http_proxy）；clash on→proxy.golang.org，off→goproxy.cn
export MIHOMO_PORT=${port}

clash() {
  local port=\"\${MIHOMO_PORT:-7890}\"
  case \"\${1:-}\" in
    on|start)
      sudo systemctl start mihomo 2>/dev/null || { echo \"[clash] 启动失败，查看: clash log\"; return 1; }
      # 等待端口就绪，避免代理未监听时全局 env 导致命令卡死
      local i=0
      while [ \"\$i\" -lt 15 ]; do
        ss -tln 2>/dev/null | grep -q \":\${port} \" && break
        sleep 1; i=\$((i+1))
      done
      if ! ss -tln 2>/dev/null | grep -q \":\${port} \"; then
        echo \"[clash] 端口 \${port} 未就绪，未设置代理环境变量（避免系统卡顿）\"
        return 1
      fi
      export http_proxy=\"http://127.0.0.1:\${port}\"
      export https_proxy=\"http://127.0.0.1:\${port}\"
      export all_proxy=\"socks5://127.0.0.1:\${port}\"
      export HTTP_PROXY=\"\$http_proxy\"
      export HTTPS_PROXY=\"\$https_proxy\"
      export ALL_PROXY=\"\$all_proxy\"
      export NO_PROXY=\"127.0.0.1,localhost,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.aliyuncs.com,.tencent.com,pypi.tuna.tsinghua.edu.cn,goproxy.cn,mirrors.aliyun.com\"
      export no_proxy=\"\$NO_PROXY\"
      export GOPROXY=https://proxy.golang.org,direct
      export GOSUMDB=sum.golang.org
      echo \"[clash] ON  -> 127.0.0.1:\${port} | GOPROXY=proxy.golang.org\"
      ;;
    off|stop)
      sudo systemctl stop mihomo 2>/dev/null || true
      unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY no_proxy
      export GOPROXY=https://goproxy.cn,direct
      export GOSUMDB=sum.golang.org
      echo \"[clash] OFF | GOPROXY=goproxy.cn\"
      ;;
    restart)
      sudo systemctl restart mihomo && echo \"[clash] 已重启\"
      ;;
    status|st)
      sudo systemctl status mihomo --no-pager
      ;;
    log)
      sudo journalctl -u mihomo -f --no-hostname
      ;;
    reload)
      sudo systemctl reload mihomo && echo \"[clash] 配置已热重载\"
      ;;
    test)
      curl -s --max-time 5 -o /dev/null -w \"Google HTTP: %{http_code}\\n\" https://www.google.com \\
        || echo \"[clash] 无响应，请先: clash on\"
      ;;
    *)
      echo \"用法: clash {on|off|restart|status|log|reload|test}\"
      echo \"  clash on     启动 mihomo + 开启代理 + GOPROXY=proxy.golang.org\"
      echo \"  clash off    停止 mihomo + 关闭代理 + GOPROXY=goproxy.cn\"
      echo \"  go-proxy-on  仅切换 GOPROXY 到官方源（不启 clash）\"
      echo \"  go-proxy-off 仅切换 GOPROXY 到国内源（不关 clash）\"
      ;;
  esac
}

alias proxyon='clash on'
alias proxyoff='clash off'
alias clash_start='clash on'
alias clash_stop='clash off'
alias clash_log='clash log'
alias clash_status='clash status'
alias go-proxy-on='export GOPROXY=https://proxy.golang.org,direct GOSUMDB=sum.golang.org && echo \"[go] GOPROXY=proxy.golang.org\"'
alias go-proxy-off='export GOPROXY=https://goproxy.cn,direct GOSUMDB=sum.golang.org && echo \"[go] GOPROXY=goproxy.cn\"'"
}

# 关闭所有代理（clash/mihomo + shell 环境变量 + Go 模块代理回国内源）
disable_all_proxy() {
  log "===== 关闭所有代理 ====="
  systemctl stop mihomo 2>/dev/null || true
  ok "已停止 mihomo (clash)"
  setup_noproxy_zshrc
  ok "已写入 .zshrc: noproxy / proxy-off-all"
  ok "当前终端请执行: source ~/.zshrc && noproxy"
}

setup_noproxy_zshrc() {
  zshrc_set "noproxy-all" "# 关闭所有代理（clash + http_proxy + GOPROXY）
noproxy() {
  type clash >/dev/null 2>&1 && clash off 2>/dev/null || true
  sudo systemctl stop mihomo 2>/dev/null || true
  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY no_proxy 2>/dev/null || true
  export GOPROXY=https://goproxy.cn,direct
  export GOSUMDB=sum.golang.org
  echo \"[noproxy] 已关闭 clash/mihomo 与所有 shell 代理变量，GOPROXY=goproxy.cn\"
}
alias proxy-off-all='noproxy'
alias noproxy-all='noproxy'"
}

# 打印 NTP / 系统时间 / 硬件时钟状态（UTF-8 终端输出）
print_time_sync_status() {
  local title="${1:-时间同步状态}"
  ensure_utf8_output
  echo ""
  echo -e "${C_YEL}════════════════ ${title} ════════════════${C_NC}"

  echo -e "${C_BLUE}[1] NTP 同步状态 & 当前系统时间 (timedatectl)${C_NC}"
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl status 2>/dev/null | tee -a "$LOG_FILE" | sed 's/^/  /'
  else
    warn "  timedatectl 不可用"
    date '+  本地时间: %Y-%m-%d %H:%M:%S %Z' | tee -a "$LOG_FILE"
  fi

  echo -e "${C_BLUE}[2] 硬件时钟 RTC (hwclock)${C_NC}"
  if command -v hwclock >/dev/null 2>&1; then
    if hwclock --show --localtime 2>/dev/null | tee -a "$LOG_FILE" | sed 's/^/  /'; then
      :
    else
      hwclock --show 2>/dev/null | tee -a "$LOG_FILE" | sed 's/^/  /' \
        || warn "  hwclock 读取失败"
    fi
  elif [ -r /sys/class/rtc/rtc0/time ]; then
    echo "  $(cat /sys/class/rtc/rtc0/time) (sysfs /sys/class/rtc/rtc0/time, 通常为 UTC)" | tee -a "$LOG_FILE"
  else
    warn "  无法读取硬件时钟（未安装 util-linux-extra 或无 RTC 设备）"
  fi

  echo -e "${C_BLUE}[3] NTP 服务器追踪 (chronyc tracking)${C_NC}"
  if command -v chronyc >/dev/null 2>&1 && systemctl is-active chrony >/dev/null 2>&1; then
    chronyc -n tracking 2>/dev/null | tee -a "$LOG_FILE" | sed 's/^/  /' \
      || warn "  chronyc tracking 失败"
  else
    warn "  chrony 未安装或未运行，跳过 tracking"
  fi

  echo -e "${C_BLUE}[4] NTP 源连接状态 (chronyc sources)${C_NC}"
  if command -v chronyc >/dev/null 2>&1 && systemctl is-active chrony >/dev/null 2>&1; then
    chronyc -n sources -v 2>/dev/null | tee -a "$LOG_FILE" | sed 's/^/  /' \
      || chronyc -n sources 2>/dev/null | tee -a "$LOG_FILE" | sed 's/^/  /' \
      || warn "  chronyc sources 失败"
  else
    warn "  chrony 未安装或未运行，跳过 sources"
  fi

  echo -e "${C_BLUE}[5] NTP 源统计 (chronyc sourcestats)${C_NC}"
  if command -v chronyc >/dev/null 2>&1 && systemctl is-active chrony >/dev/null 2>&1; then
    chronyc -n sourcestats 2>/dev/null | tee -a "$LOG_FILE" | sed 's/^/  /' \
      || warn "  chronyc sourcestats 失败"
  else
    warn "  chrony 未安装或未运行，跳过 sourcestats"
  fi
  echo ""
}

# 上海时区 + NTP 自动时间同步
setup_time_sync() {
  ensure_utf8_output
  log "===== 配置时区与时间同步 (Asia/Shanghai) ====="
  print_time_sync_status "配置前 · 时间状态"

  apt_install chrony tzdata || return 1

  if timedatectl set-timezone Asia/Shanghai 2>>"$LOG_FILE"; then
    ok "时区已设为 Asia/Shanghai"
  else
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    ok "时区已设为 Asia/Shanghai（localtime）"
  fi

  mkdir -p /etc/chrony/sources.d
  cat > /etc/chrony/sources.d/vps-auto-ntp.sources <<'EOF'
# vps_auto_work_cc.sh — 国内优先 NTP
pool ntp.aliyun.com iburst maxsources 4
pool cn.pool.ntp.org iburst maxsources 2
pool ntp.tencent.com iburst maxsources 2
EOF
  chmod 644 /etc/chrony/sources.d/vps-auto-ntp.sources

  systemctl enable chrony >> "$LOG_FILE" 2>&1 || true
  systemctl restart chrony >> "$LOG_FILE" 2>&1 || true
  sleep 3
  chronyc -a makestep >> "$LOG_FILE" 2>&1 || true

  timedatectl set-ntp true 2>>"$LOG_FILE" || true

  # 将已校准的系统时间写回硬件时钟（若支持）
  if command -v hwclock >/dev/null 2>&1; then
    hwclock --systohc --localtime >> "$LOG_FILE" 2>&1 \
      || hwclock --systohc >> "$LOG_FILE" 2>&1 \
      || warn "hwclock --systohc 失败（部分云主机无 RTC 写入权限）"
  fi

  ok "NTP 自动同步已启用（chrony + 阿里云/国内池）"
  print_time_sync_status "配置后 · 时间状态"
}

# ───────────────────────── 流量统计（vnstat 历史累计 + nethogs 进程采样）─────────────────────────
get_default_iface() {
  local iface
  iface=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ -n "$iface" ] && { echo "$iface"; return 0; }
  iface=$(ip -o link show up 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')
  echo "${iface:-eth0}"
}

format_bytes_human() {
  local b="${1:-0}"
  awk -v b="$b" 'BEGIN {
    if (b >= 1073741824) printf "%.2f GiB", b/1073741824;
    else if (b >= 1048576) printf "%.2f MiB", b/1048576;
    else if (b >= 1024) printf "%.2f KiB", b/1024;
    else printf "%d B", b;
  }'
}

print_iface_boot_traffic() {
  local iface="$1" line rx tx
  line=$(awk -v d="${iface}:" '$1==d {print $0}' /proc/net/dev 2>/dev/null)
  [ -z "$line" ] && { warn "  无法读取 /proc/net/dev 中 ${iface} 统计"; return 1; }
  read -r _ rx _ _ _ _ _ tx _ <<< "$line"
  ok "  自本次启动累计（${iface}）: 下行 $(format_bytes_human "$rx") / 上行 $(format_bytes_human "$tx")"
}

print_nethogs_top() {
  local iface="$1" sample_sec="${2:-8}"
  if ! command -v nethogs >/dev/null 2>&1; then
    warn "nethogs 未安装，跳过进程流量采样"
    return 1
  fi
  log "进程流量采样 ${sample_sec}s（nethogs · ${iface}）..."
  local tmp sorted
  tmp=$(mktemp /tmp/vps_nethogs.XXXXXX)
  timeout "$sample_sec" nethogs -t -d 2 -v 3 "$iface" 2>/dev/null > "$tmp" || true
  if [ ! -s "$tmp" ]; then
    warn "nethogs 无采样数据（可能当前无流量或需 root）"
    rm -f "$tmp"
    return 1
  fi
  sorted=$(awk -F'\t' '
    NF >= 5 && $2 != "" && $2 != "UNKNOWN" {
      sent = $4 + 0; recv = $5 + 0; total = sent + recv
      if (total > 0) agg[$2] += total
    }
    END {
      for (p in agg) print agg[p], p
    }' "$tmp" | sort -rn | head -10)
  rm -f "$tmp"
  if [ -z "$sorted" ]; then
    warn "采样期间未识别到进程流量"
    return 1
  fi
  echo "$sorted" | while read -r total_mb proc; do
    printf "  %-10s  %s\n" "${total_mb}MB" "$proc"
  done | tee -a "$LOG_FILE"
  return 0
}

print_traffic_status() {
  local title="${1:-流量统计}"
  local iface sample_sec="${2:-8}"
  ensure_utf8_output
  iface=$(get_default_iface)
  echo ""
  echo -e "${C_YEL}════════════════ ${title} ════════════════${C_NC}"
  echo -e "${C_BLUE}监控网卡: ${iface}${C_NC}"

  echo -e "${C_BLUE}[1] vnstat 历史累计（自 vnstat 启用以来）${C_NC}"
  if command -v vnstat >/dev/null 2>&1; then
    if vnstat -i "$iface" 2>/dev/null | tee -a "$LOG_FILE" | sed 's/^/  /' | grep -q .; then
      if vnstat -i "$iface" 2>/dev/null | grep -qiE 'No data|not enough data'; then
        warn "  vnstat 数据库尚无足够样本，下方为自本次启动的接口计数"
        print_iface_boot_traffic "$iface"
      fi
    else
      warn "  vnstat 查询失败"
      print_iface_boot_traffic "$iface"
    fi
    echo -e "${C_BLUE}[2] vnstat 按月统计${C_NC}"
    vnstat -i "$iface" -m 2>/dev/null | tee -a "$LOG_FILE" | sed 's/^/  /' || warn "  月度统计暂无"
    echo -e "${C_BLUE}[3] vnstat 按日统计（近月）${C_NC}"
    vnstat -i "$iface" -d 2>/dev/null | tee -a "$LOG_FILE" | sed 's/^/  /' || warn "  日统计暂无"
  else
    warn "  vnstat 未安装，仅显示自启动以来接口计数"
    print_iface_boot_traffic "$iface"
  fi

  echo -e "${C_BLUE}[4] 进程流量 TOP（nethogs 实时采样，合计 MB）${C_NC}"
  print_nethogs_top "$iface" "$sample_sec" || true
  echo -e "${C_BLUE}[提示]${C_NC} 历史累计: vnstat -i ${iface}  |  实时进程: sudo nethogs ${iface}"
  echo ""
}

setup_traffic_zshrc() {
  local script_path="$1"
  zshrc_set "traffic-monitor" "# 流量统计（vnstat 历史 + nethogs 进程 TOP）
traffic-check() {
  sudo bash ${script_path} -traffic-check
}
traffic-top() {
  local iface=\$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i==\"dev\"){print \$(i+1); exit}}')
  iface=\${iface:-eth0}
  sudo nethogs -v 3 \"\$iface\"
}"
}

setup_traffic_monitor() {
  ensure_utf8_output
  log "===== 配置流量统计（vnstat + nethogs）====="
  apt_install vnstat nethogs || { err "vnstat/nethogs 安装失败"; return 1; }

  local iface script_path
  iface=$(get_default_iface)
  script_path=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")

  if command -v vnstat >/dev/null 2>&1; then
    vnstat --add -i "$iface" >> "$LOG_FILE" 2>&1 || true
    systemctl enable vnstat >> "$LOG_FILE" 2>&1 || true
    systemctl restart vnstat >> "$LOG_FILE" 2>&1 || true
    sleep 2
    vnstat -u -i "$iface" -f >> "$LOG_FILE" 2>&1 || true
    ok "vnstat 已监控网卡 ${iface}（systemd: vnstat）"
  fi

  setup_traffic_zshrc "$script_path"
  ok "已写入 .zshrc: traffic-check / traffic-top"
  print_traffic_status "初始化后 · 流量统计"
}

print_clash_usage_summary() {
  local cfg_src="${1:-/etc/mihomo/config.yaml}"
  local port="${2:-7890}"
  echo ""
  echo -e "${C_GREEN}════════════════ clash / mihomo 安装完成 ════════════════${C_NC}"
  echo -e "  配置文件 : ${cfg_src}"
  echo -e "  运行配置 : /etc/mihomo/config.yaml"
  echo -e "  代理端口 : ${port}    控制面板: http://127.0.0.1:9090"
  echo ""
  echo -e "  ${C_BLUE}▶ 先执行一次:${C_NC}  source ~/.zshrc"
  echo ""
  echo -e "  ${C_BLUE}常用命令:${C_NC}"
  echo -e "    ${C_YEL}clash on${C_NC}        启动服务 + 开启代理 + GOPROXY=proxy.golang.org"
  echo -e "    ${C_YEL}proxyon${C_NC}         同 clash on"
  echo -e "    clash off       停止服务 + 关闭代理 + GOPROXY=goproxy.cn"
  echo -e "    proxyoff        同 clash off"
  echo -e "    go-proxy-on/off 仅切换 Go 模块源（不启停 clash）"
  echo -e "    clash status    查看服务状态"
  echo -e "    clash log       查看实时日志"
  echo -e "    clash test      测试 Google 连通性"
  echo -e "    clash reload    热重载配置"
  echo ""
  echo -e "  更换配置: sudo bash ${SCRIPT_NAME} -clash /path/to/config.yaml"
  echo -e "  开机自启: sudo systemctl enable mihomo"
  echo -e "${C_GREEN}════════════════════════════════════════════════════════${C_NC}"
}

install_clash() {
  local yaml_source="${1:-}"

  log "===== mihomo (Clash Meta) 安装 ====="
  load_region_if_needed

  local mihomo_bin="/usr/local/bin/mihomo"
  local mihomo_cfg="/etc/mihomo"
  local profile_conf="${mihomo_cfg}/profile.conf"
  local proxy_port=7890
  local arch="amd64"
  case "$(uname -m)" in aarch64|arm64) arch="arm64" ;; esac

  # ── 1. mihomo 二进制：已安装则跳过下载，直接进入配置 ──
  if [ -x "$mihomo_bin" ]; then
    ok "mihomo 已安装，跳过下载 → 进入配置文件步骤"
    ok "  版本: $($mihomo_bin -v 2>/dev/null | head -1)"
  elif command -v mihomo >/dev/null 2>&1 && [ -x "$(command -v mihomo)" ]; then
    ok "检测到 mihomo 已存在: $(command -v mihomo)，跳过下载 → 进入配置文件步骤"
    ln -sf "$(command -v mihomo)" "$mihomo_bin" 2>/dev/null || true
  else
    log "未检测到 mihomo，自动下载 linux-${arch} 最新版..."
    local download_url
    download_url=$(resolve_mihomo_download_url "$arch")
    ok "匹配到: ${download_url}"
    if ! install_mihomo_binary "$download_url"; then
      warn "在线下载均失败（国内可浏览器下载后上传到 VPS）"
      read -r -p "请输入本地 mihomo .gz 文件路径（回车放弃）: " local_gz
      if [ -n "$local_gz" ]; then
        install_mihomo_binary "$local_gz" || return 1
      else
        err "未安装 mihomo，可手动下载: https://github.com/MetaCubeX/mihomo/releases/latest"
        return 1
      fi
    fi
  fi

  # ── 2. 部署配置文件（-clash 参数 = yaml 路径或订阅 URL）──
  if [ -n "$yaml_source" ]; then
    deploy_mihomo_config "$yaml_source" || return 1
    proxy_port="$MIHOMO_PROXY_PORT"
  elif [ -f "$profile_conf" ] && [ -f "${mihomo_cfg}/config.yaml" ]; then
    # shellcheck disable=SC1090
    . "$profile_conf"
    ok "配置已就绪: ${CONFIG_SOURCE:-${mihomo_cfg}/config.yaml}（端口: ${MIHOMO_PORT:-7890}）"
    read -r -p "是否更换配置文件？(y/N): " change_cfg
    if [[ "$change_cfg" =~ ^[Yy]$ ]]; then
      read -r -p "请输入 config.yaml 路径或订阅 URL: " yaml_source
      deploy_mihomo_config "$yaml_source" || return 1
      proxy_port="$MIHOMO_PROXY_PORT"
    else
      proxy_port="${MIHOMO_PORT:-7890}"
      yaml_source="${CONFIG_SOURCE:-${mihomo_cfg}/config.yaml}"
    fi
  else
    echo ""
    echo "  请指定 clash/mihomo 配置文件:"
    echo "  1) 本地 yaml 文件路径（推荐）"
    echo "  2) 订阅链接（yaml 格式）"
    read -r -p "请选择 [1/2]: " cfg_choice
    case "$cfg_choice" in
      2)
        read -r -p "请输入订阅链接: " yaml_source
        ;;
      *)
        read -r -p "请输入 config.yaml 的完整路径: " yaml_source
        ;;
    esac
    deploy_mihomo_config "$yaml_source" || return 1
    proxy_port="$MIHOMO_PROXY_PORT"
  fi

  # shellcheck disable=SC1090
  [ -f "$profile_conf" ] && . "$profile_conf"
  yaml_source="${CONFIG_SOURCE:-$yaml_source}"

  if [ -f "${mihomo_cfg}/config.yaml" ]; then
    log "当前配置关键字段:"
    grep -E "^(mixed-port|external-controller|allow-lan|mode|log-level)" "${mihomo_cfg}/config.yaml" \
      | while read -r line; do echo "    ${line}"; done
  fi

  # ── 3. 下载 GEO 数据库（镜像失败则走 mihomo 代理）──
  load_region_if_needed
  download_geo_databases || true

  # ── 4. systemd 服务 ──
  if [ -f /etc/systemd/system/mihomo.service ]; then
    ok "systemd 服务已存在，跳过注册"
  else
  cat > /etc/systemd/system/mihomo.service << EOF
[Unit]
Description=Mihomo (Clash Meta) Proxy Service
Documentation=https://wiki.metacubex.one
After=network.target NetworkManager.service systemd-networkd.service

[Service]
Type=simple
ExecStart=${mihomo_bin} -d ${mihomo_cfg}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    ok "systemd 服务已注册（默认不自启）"
  fi

  # ── 5. 写入/更新 zshrc 快捷命令 ──
  setup_clash_zshrc "$proxy_port"

  print_clash_usage_summary "$yaml_source" "$proxy_port"
}

# ───────────────────────── 通用 GitHub 最新 Release 下载器 ─────────────────────────
# 用法: github_download <user/repo> <文件名关键词> <保存路径>
# 例如: github_download "projectdiscovery/nuclei" "linux_amd64.zip" "/tmp/nuclei.zip"
github_download() {
  local repo="$1"        # e.g. projectdiscovery/nuclei
  local keyword="$2"     # 文件名关键词，用于在 assets 中匹配
  local dest="$3"        # 下载保存路径

  log "正在查询 ${repo} 最新 Release..."
  local api_url="https://api.github.com/repos/${repo}/releases/latest"
  local download_url
  download_url=$(curl -s --max-time 10 "$api_url" \
    | grep "browser_download_url" \
    | grep "$keyword" \
    | grep -v ".sha256\|.md5\|.txt\|.json" \
    | head -1 \
    | cut -d '"' -f4)

  if [ -z "$download_url" ]; then
    err "未能从 ${repo} 获取匹配 '${keyword}' 的下载链接，请检查网络或手动前往:"
    err "https://github.com/${repo}/releases/latest"
    return 1
  fi

  log "下载: ${download_url}"
  wget -q --show-progress -O "$dest" "$download_url" || {
    err "下载失败: ${download_url}"
    return 1
  }
  ok "下载完成 → ${dest}"
}

# ───────────────────────── 安全工具目录初始化 ─────────────────────────
TOOLS_DIR="/opt/tools"
ENV_DIR="/root/git/Env"

init_tools_dir() {
  mkdir -p "${TOOLS_DIR}/bin" "${ENV_DIR}"
  zshrc_append "tools-path" "export TOOLS_DIR=${TOOLS_DIR}
export ENV_DIR=${ENV_DIR}
export PATH=\$PATH:/usr/local/go/bin:\${GOPATH:-/root/go}/bin:${TOOLS_DIR}/bin"
  ok "安全工具目录: ${TOOLS_DIR} | Env 工具: ${ENV_DIR}"
}

# 确保 go 与 GOPATH/bin 可用（-sectools 可单独运行，未必先执行 -go）
ensure_go_env() {
  if [ -z "${IS_CN:-}" ]; then
    load_region_config 2>/dev/null || IS_CN="no"
  fi
  export PATH="/usr/local/go/bin:${GOPATH:-/root/go}/bin:${PATH}"
  export GOPATH="${GOPATH:-/root/go}"
  if [ "$IS_CN" = "yes" ]; then
    export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
  fi
  if ! command -v go >/dev/null 2>&1; then
    warn "未检测到 go，先执行 install_golang..."
    install_golang || return 1
    export PATH="/usr/local/go/bin:${GOPATH}/bin:${PATH}"
  fi
  mkdir -p "${GOPATH}/bin"
}

# go install 并链接到 TOOLS_DIR/bin（已存在则跳过，除非 SECTOOLS_FORCE=1）
go_install_tool() {
  local pkg="$1"
  local bin_name="$2"
  ensure_go_env || return 1

  local existing
  existing=$(resolve_tool_bin "$bin_name")
  if [ -n "$existing" ] && sectools_should_skip; then
    ln -sf "$existing" "${TOOLS_DIR}/bin/${bin_name}" 2>/dev/null || true
    ok "${bin_name} 已安装，跳过: $(tool_version_line "$existing")"
    return 0
  fi

  log "go install ${pkg} ..."
  if ! go install -v "${pkg}" >> "$LOG_FILE" 2>&1; then
    err "go install 失败: ${pkg}（国内可先 clash on，或检查 GOPROXY）"
    return 1
  fi
  local src="${GOPATH}/bin/${bin_name}"
  if [ ! -x "$src" ]; then
    err "未找到编译产物: ${src}"
    return 1
  fi
  ln -sf "$src" "${TOOLS_DIR}/bin/${bin_name}"
  ok "${bin_name} 安装完成: $("${TOOLS_DIR}/bin/${bin_name}" -version 2>&1 | head -1 || "${TOOLS_DIR}/bin/${bin_name}" -h 2>&1 | head -1 || echo ok)"
}

# git clone 到 ENV_DIR（国内网络失败时提示 clash on）
env_git_clone() {
  local repo_url="$1"
  local dest="$2"
  if [ -d "${dest}/.git" ]; then
    if [ "${SECTOOLS_FORCE:-0}" = "1" ]; then
      log "已存在 ${dest}，git pull 更新..."
      git -C "$dest" pull --ff-only >> "$LOG_FILE" 2>&1 || warn "git pull 失败，继续使用现有版本"
    else
      ok "仓库已存在，跳过克隆/更新: ${dest}"
    fi
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  log "克隆 ${repo_url} → ${dest}"
  if git clone --depth=1 "$repo_url" "$dest" >> "$LOG_FILE" 2>&1; then
    return 0
  fi
  warn "git clone 失败，可尝试: clash on && 重试"
  return 1
}

# 解析工具二进制路径（TOOLS_DIR → GOPATH/bin → PATH）
resolve_tool_bin() {
  local name="$1"
  if [ -x "${TOOLS_DIR}/bin/${name}" ]; then
    echo "${TOOLS_DIR}/bin/${name}"
  elif [ -x "${GOPATH:-/root/go}/bin/${name}" ]; then
    echo "${GOPATH:-/root/go}/bin/${name}"
  elif command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
  fi
}

tool_version_line() {
  local bin="$1"
  [ -n "$bin" ] && [ -x "$bin" ] || { echo "missing"; return; }
  "$bin" -version 2>/dev/null | head -1 \
    || "$bin" --version 2>/dev/null | head -1 \
    || "$bin" -V 2>/dev/null | head -1 \
    || echo "ok"
}

sectools_should_skip() {
  [ "${SECTOOLS_FORCE:-0}" != "1" ]
}

# 检查单个 go/apt 工具是否已就绪
go_tool_ready() {
  local name="$1"
  local bin
  bin=$(resolve_tool_bin "$name")
  [ -n "$bin" ] && [ -x "$bin" ]
}

# 打印 EASM 安全工具分类说明（帮助理解 -sectools 套件）
print_sectools_catalog() {
  cat <<EOF

  ${C_YEL}EASM 安全工具分类（-sectools 一键安装下列全部）${C_NC}

  ┌─ ① 信息收集 / 子域枚举 ─────────────────────────────────
  │  oneforall   国产多源子域聚合（Python venv）
  │  subfinder   被动子域（40+ 数据源，需 provider-config）
  │  amass       OWASP 子域枚举（被动/主动）
  │  enscan      企业工商/ICP 备案（需 tar 包 + Cookie）
  │  uncover     空间引擎 CLI（Hunter/FOFA/Quake 等 ICP 反查）
  │
  ├─ ② DNS 解析 / 爆破 ─────────────────────────────────────
  │  dnsx        DNS 解析验证、轻量字典爆破
  │  shuffledns  高速子域爆破（依赖 massdns + resolvers.txt）
  │
  ├─ ③ 探活 / 指纹 / 资产识别 ─────────────────────────────
  │  httpx       HTTP 探活、title、favicon、tech-detect
  │  ehole       红队重点系统指纹（OA/VPN/Weblogic 等）
  │  urlfinder   JS/隐藏 URL 提取
  │  gowitness   Web 页面截图归档
  │
  ├─ ④ 端口扫描 / 服务识别 ─────────────────────────────────
  │  masscan     高速全端口发现（需 root 或 setcap）
  │  nmap        服务版本与脚本扫描（-sV -sC）
  │  naabu       域名维度端口扫描（可管道 httpx）
  │  fscan       Go 端口扫描补充（EASM 务必 -nobr -nopoc）
  │
  ├─ ⑤ CDN 穿透 / 真实 IP ──────────────────────────────────
  │  fav-up      Favicon Hash → Shodan 反查源站 IP
  │
  └─ ⑥ 漏洞扫描（可选，需授权）──────────────────────────────
     nuclei      模板化漏洞/暴露面扫描（高价值 URL 轻量扫）

  推荐流程: enscan/备案 → uncover ICP 反查 → subfinder/oneforall
            → dnsx/shuffledns → httpx/ehole → naabu/fscan → fav-up → nuclei(可选)
  API Key: 见 CyberStrikeAI skills/easm-recon/references/06-api-credentials.md
  GitHub:  https://github.com/alpha302/MyTools

EOF
}

# 打印安全工具安装状态（-sectools-check / -sectools 开头）
check_sectools_status() {
  mkdir -p "${TOOLS_DIR}/bin" "${ENV_DIR}" 2>/dev/null || true
  echo ""
  echo -e "${C_YEL}── 安全工具安装状态 ──${C_NC}"
  local name path ver
  local ready=0 total=0

  _sectool_row() {
    local label="$1" path="$2" ver="$3"
    total=$((total + 1))
    if [ -n "$path" ] && [ -x "$path" ]; then
      ready=$((ready + 1))
      echo -e "  ${C_GREEN}[已安装]${C_NC} ${label}  ${ver}  (${path})"
    else
      echo -e "  ${C_YEL}[未安装]${C_NC} ${label}"
    fi
  }

  _sectool_category() {
    echo -e "  ${C_BLUE}[$1]${C_NC} $2"
  }

  _sectool_category "①信息收集" "子域枚举 / 企业备案 / 空间引擎"
  for name in oneforall subfinder amass enscan uncover; do
    case "$name" in
      oneforall) path="${TOOLS_DIR}/bin/oneforall"; ver=$([ -x "$path" ] && echo "wrapper ok" || echo "missing") ;;
      enscan) path="${ENV_DIR}/ENScan_GO/enscan"; [ ! -x "$path" ] && path=$(resolve_tool_bin enscan); ver=$(tool_version_line "$path") ;;
      *) path=$(resolve_tool_bin "$name"); ver=$(tool_version_line "$path") ;;
    esac
    _sectool_row "$name" "$path" "$ver"
  done

  _sectool_category "②DNS" "解析验证 / 子域爆破"
  for name in dnsx shuffledns; do
    path=$(resolve_tool_bin "$name"); ver=$(tool_version_line "$path")
    _sectool_row "$name" "$path" "$ver"
  done

  _sectool_category "③探活指纹" "HTTP 探活 / 系统指纹 / JS / 截图"
  path=$(resolve_tool_bin httpx); ver=$(tool_version_line "$path"); _sectool_row "httpx" "$path" "$ver"
  path="${ENV_DIR}/EHole/EHole"; [ ! -x "$path" ] && path=$(resolve_tool_bin ehole); ver=$(tool_version_line "$path"); _sectool_row "ehole" "$path" "$ver"
  path="${ENV_DIR}/URLFinder/URLFinder"; [ ! -x "$path" ] && path=$(resolve_tool_bin urlfinder); ver=$(tool_version_line "$path"); _sectool_row "urlfinder" "$path" "$ver"
  path=$(resolve_tool_bin gowitness); ver=$(tool_version_line "$path"); _sectool_row "gowitness" "$path" "$ver"

  _sectool_category "④端口扫描" "masscan / nmap / naabu / fscan"
  for name in masscan nmap naabu fscan; do
    path=$(resolve_tool_bin "$name"); ver=$(tool_version_line "$path")
    _sectool_row "$name" "$path" "$ver"
  done

  _sectool_category "⑤CDN穿透" "Favicon → Shodan 找真实 IP"
  path="${TOOLS_DIR}/bin/favup"; ver=$([ -x "$path" ] && echo "wrapper ok" || echo "missing")
  _sectool_row "favup" "$path" "$ver"

  _sectool_category "⑥漏洞扫描" "Nuclei 模板（可选，需授权）"
  path=$(resolve_tool_bin nuclei); ver=$(tool_version_line "$path")
  _sectool_row "nuclei" "$path" "$ver"

  echo ""
  echo -e "  合计: ${ready}/${total} 已就绪"
  echo -e "  强制重装: ${C_YEL}SECTOOLS_FORCE=1 sudo bash ${SCRIPT_NAME} -sectools${C_NC}"
  echo -e "  分类说明: ${C_YEL}bash ${SCRIPT_NAME} -sectools-help${C_NC}"
  echo ""
}

# ───────────────────────── OneForAll ─────────────────────────
install_oneforall() {
  log "===== 安装 OneForAll (子域名枚举) ====="
  init_tools_dir

  local ofa_dir="${TOOLS_DIR}/OneForAll"
  if [ -x "${TOOLS_DIR}/bin/oneforall" ] \
     && [ -x "${ofa_dir}/venv/bin/python" ] \
     && [ -f "${ofa_dir}/oneforall/oneforall.py" ] \
     && sectools_should_skip; then
    ok "OneForAll 已安装，跳过: ${ofa_dir}"
    return 0
  fi

  apt_install python3 python3-pip python3-venv git || warn "OneForAll 依赖安装失败"

  # 克隆（已存在则跳过，不 pull）
  if [ -d "${ofa_dir}/.git" ]; then
    ok "OneForAll 仓库已存在，跳过克隆: ${ofa_dir}"
  else
    log "克隆 OneForAll..."
    if [ "$IS_CN" = "yes" ]; then
      # 国内走 gitee 镜像（shmilylty 官方在 gitee 有同步镜像）
      git clone --depth=1 https://gitee.com/shmilylty/OneForAll.git "$ofa_dir" >> "$LOG_FILE" 2>&1 \
        || git clone --depth=1 https://github.com/shmilylty/OneForAll.git "$ofa_dir" >> "$LOG_FILE" 2>&1
    else
      git clone --depth=1 https://github.com/shmilylty/OneForAll.git "$ofa_dir" >> "$LOG_FILE" 2>&1
    fi
  fi

  if [ ! -d "$ofa_dir" ]; then
    err "OneForAll 克隆失败"; return 1
  fi

  # 创建 Python 虚拟环境（已存在则跳过）
  if [ -x "${ofa_dir}/venv/bin/python" ] && sectools_should_skip; then
    ok "OneForAll venv 已存在，跳过 pip 安装"
  else
  log "创建 Python 虚拟环境: ${ofa_dir}/venv"
  python3 -m venv "${ofa_dir}/venv" >> "$LOG_FILE" 2>&1

  # 安装依赖（国内切换 pip 源）
  local pip_extra=""
  [ "$IS_CN" = "yes" ] && pip_extra="-i https://pypi.tuna.tsinghua.edu.cn/simple"

  log "安装 Python 依赖（requirements.txt）..."
  "${ofa_dir}/venv/bin/pip" install --upgrade pip $pip_extra >> "$LOG_FILE" 2>&1
  "${ofa_dir}/venv/bin/pip" install -r "${ofa_dir}/requirements.txt" $pip_extra >> "$LOG_FILE" 2>&1 \
    || { err "OneForAll 依赖安装失败，请查看 ${LOG_FILE}"; return 1; }
  fi

  # 创建全局调用封装脚本，自动激活 venv，不需要用户手动 source
  cat > "${TOOLS_DIR}/bin/oneforall" << EOF
#!/usr/bin/env bash
# OneForAll 封装器：自动使用虚拟环境，无需手动 source activate
exec "${ofa_dir}/venv/bin/python" "${ofa_dir}/oneforall/oneforall.py" "\$@"
EOF
  chmod +x "${TOOLS_DIR}/bin/oneforall"

  # brute 子命令封装
  cat > "${TOOLS_DIR}/bin/oneforall-brute" << EOF
#!/usr/bin/env bash
exec "${ofa_dir}/venv/bin/python" "${ofa_dir}/oneforall/brute.py" "\$@"
EOF
  chmod +x "${TOOLS_DIR}/bin/oneforall-brute"

  # 写入 zshrc 方便直接 cd 进目录
  zshrc_append "oneforall" "alias ofa='oneforall'
alias cdofa='cd ${ofa_dir}'"

  ok "OneForAll 安装完成"
  ok "  直接调用: oneforall --target example.com --run"
  ok "  目录: ${ofa_dir}"
  ok "  venv: ${ofa_dir}/venv（封装脚本已处理，无需手动 source activate）"
}

# ───────────────────────── Nuclei ─────────────────────────
# 安装/更新 nuclei-templates（与二进制安装解耦，避免「有 nuclei 无模板」）
install_nuclei_templates() {
  init_tools_dir
  local tpl_dir="${TOOLS_DIR}/nuclei-templates"
  local nuclei_bin="${TOOLS_DIR}/bin/nuclei"
  local yaml_count=0

  _nuclei_tpl_yaml_count() {
    find "$tpl_dir" -name '*.yaml' -type f 2>/dev/null | wc -l | tr -d ' '
  }

  yaml_count=$(_nuclei_tpl_yaml_count)
  if [ "${yaml_count:-0}" -gt 100 ] && sectools_should_skip; then
    ok "nuclei-templates 已就绪: ${tpl_dir}（约 ${yaml_count} 个 yaml），跳过下载"
    zshrc_append "nuclei" "export NUCLEI_TEMPLATES=${tpl_dir}"
    return 0
  fi

  log "下载/更新 nuclei-templates → ${tpl_dir}"
  apt_install git || true

  if [ -d "${tpl_dir}/.git" ]; then
    git -C "$tpl_dir" pull --ff-only >> "$LOG_FILE" 2>&1 \
      || warn "templates git pull 失败，将尝试 nuclei -update-templates"
  else
    rm -rf "$tpl_dir"
    git clone --depth=1 https://github.com/projectdiscovery/nuclei-templates.git "$tpl_dir" >> "$LOG_FILE" 2>&1 \
      || warn "templates git clone 失败，将尝试 nuclei -update-templates"
  fi

  yaml_count=$(_nuclei_tpl_yaml_count)
  if [ "${yaml_count:-0}" -lt 100 ]; then
    if [ -x "$nuclei_bin" ]; then
      log "模板数量不足（${yaml_count:-0}），使用 nuclei -update-templates 补充..."
      mkdir -p "$tpl_dir"
      NUCLEI_TEMPLATES="$tpl_dir" "$nuclei_bin" -update-templates -update-template-dir "$tpl_dir" -duc >> "$LOG_FILE" 2>&1 \
        || warn "nuclei -update-templates 失败"
      yaml_count=$(_nuclei_tpl_yaml_count)
    else
      warn "nuclei 二进制未安装，无法使用 -update-templates 兜底"
    fi
  fi

  zshrc_append "nuclei" "export NUCLEI_TEMPLATES=${tpl_dir}"

  if [ "${yaml_count:-0}" -lt 10 ]; then
    warn "nuclei-templates 未就绪（yaml=${yaml_count:-0}），扫描会报: no templates provided for scan"
    warn "  手动修复: git clone --depth=1 https://github.com/projectdiscovery/nuclei-templates.git ${tpl_dir}"
    warn "  或: NUCLEI_TEMPLATES=${tpl_dir} nuclei -update-templates -update-template-dir ${tpl_dir}"
    return 1
  fi

  ok "nuclei-templates 就绪: ${tpl_dir}（约 ${yaml_count} 个 yaml）"
  return 0
}

install_nuclei() {
  log "===== 安装 Nuclei (漏洞扫描) ====="
  init_tools_dir

  if [ -x "${TOOLS_DIR}/bin/nuclei" ] && sectools_should_skip; then
    ok "Nuclei 已安装，跳过二进制: $(tool_version_line "${TOOLS_DIR}/bin/nuclei")"
  else
    local arch="amd64"
    case "$(uname -m)" in aarch64|arm64) arch="arm64" ;; esac
    local tmp_zip="/tmp/nuclei.zip"

    github_download "projectdiscovery/nuclei" "linux_${arch}.zip" "$tmp_zip" || return 1

    apt_install unzip || true
    unzip -qo "$tmp_zip" -d /tmp/nuclei_extract >> "$LOG_FILE" 2>&1
    mv -f /tmp/nuclei_extract/nuclei "${TOOLS_DIR}/bin/nuclei"
    chmod +x "${TOOLS_DIR}/bin/nuclei"
    rm -rf "$tmp_zip" /tmp/nuclei_extract
    ok "Nuclei 二进制: $(${TOOLS_DIR}/bin/nuclei -version 2>&1 | head -1)"
  fi

  install_nuclei_templates || warn "nuclei-templates 未完整安装，请检查网络或手动更新"

  ok "  调用: nuclei -u https://example.com -t ${TOOLS_DIR}/nuclei-templates/http/exposures/"
  ok "  环境: export NUCLEI_TEMPLATES=${TOOLS_DIR}/nuclei-templates"
  ok "  更新: nuclei -update && nuclei -update-templates"
}

# ───────────────────────── httpx ─────────────────────────
install_httpx() {
  log "===== 安装 httpx (HTTP 探活/指纹) ====="
  init_tools_dir
  # pip 的 Python httpx CLI 会占用 /usr/local/bin/httpx，导致 -l 等 PD 参数失效
  if [ -f /usr/local/bin/httpx ] && head -1 /usr/local/bin/httpx 2>/dev/null | grep -qi python; then
    mv -f /usr/local/bin/httpx /usr/local/bin/httpx-python-cli 2>/dev/null || true
    warn "已将 Python httpx CLI 重命名为 httpx-python-cli，避免与 ProjectDiscovery httpx 冲突"
  fi
  go_install_tool "github.com/projectdiscovery/httpx/cmd/httpx@latest" "httpx" || return 1
  local pd_httpx
  pd_httpx=$(resolve_tool_bin httpx)
  [ -n "$pd_httpx" ] && ln -sf "$pd_httpx" "${TOOLS_DIR}/bin/httpx"
  ok "  二进制: ${TOOLS_DIR}/bin/httpx（勿与 pip httpx 混淆）"
  ok "  调用: /opt/tools/bin/httpx -l domains.txt -title -status-code -tech-detect -favicon -json -o out.json"
}

# ───────────────────────── naabu ─────────────────────────
install_naabu() {
  log "===== 安装 naabu (端口扫描) ====="
  init_tools_dir
  if ! go_tool_ready naabu; then
    apt_install libpcap-dev || warn "libpcap-dev 安装失败，naabu 可能无法编译"
  elif sectools_should_skip; then
    ok "libpcap-dev / naabu 已就绪，跳过 apt"
  fi
  go_install_tool "github.com/projectdiscovery/naabu/v2/cmd/naabu@latest" "naabu" || return 1
  ok "  调用: naabu -host target.com -top-ports 1000 -rate 1000 -o ports.txt"
  ok "  无 root 时可加: -scan-type connect"
}

# ───────────────────────── dnsx ─────────────────────────
install_dnsx() {
  log "===== 安装 dnsx (DNS 解析/验证/爆破) ====="
  init_tools_dir
  go_install_tool "github.com/projectdiscovery/dnsx/cmd/dnsx@latest" "dnsx" || return 1
  ok "  解析: dnsx -l subs.txt -a -resp -o resolved.txt"
  ok "  爆破: dnsx -d target.com -w wordlist.txt -o brute.txt"
}

# ───────────────────────── shuffledns ─────────────────────────
install_shuffledns() {
  log "===== 安装 shuffledns (高速子域爆破) ====="
  init_tools_dir
  if ! command -v massdns >/dev/null 2>&1; then
    apt_install massdns || warn "massdns 未安装，shuffledns 运行需 -massdns 指定路径"
  elif sectools_should_skip; then
    ok "massdns 已安装，跳过 apt"
  fi
  go_install_tool "github.com/projectdiscovery/shuffledns/cmd/shuffledns@latest" "shuffledns" || return 1
  local resolvers="${ENV_DIR}/resolvers.txt"
  if [ ! -f "$resolvers" ]; then
    cat > "$resolvers" <<'EOF'
8.8.8.8
8.8.4.4
1.1.1.1
1.0.0.1
EOF
    ok "已生成默认解析器列表: ${resolvers}"
  fi
  ok "  爆破: shuffledns -d target.com -list wordlist.txt -r ${resolvers} -massdns \$(which massdns)"
  ok "  验证: shuffledns -d target.com -list subs.txt -r ${resolvers} -mode verify"
}
install_gowitness() {
  log "===== 安装 gowitness (Web 截图) ====="
  init_tools_dir
  local gw_bin
  gw_bin=$(resolve_tool_bin gowitness)
  if [ -n "$gw_bin" ] && sectools_should_skip; then
    ln -sf "$gw_bin" "${TOOLS_DIR}/bin/gowitness" 2>/dev/null || true
    ok "gowitness 已安装，跳过: $(tool_version_line "$gw_bin")"
    return 0
  fi
  apt_install libnss3 libatk-bridge2.0-0 libdrm2 libxkbcommon0 libgbm1 \
    libasound2t64 libxshmfence1 fonts-liberation 2>/dev/null \
    || apt_install libnss3 libatk-bridge2.0-0 libdrm2 libxkbcommon0 libgbm1 \
       libasound2 libxshmfence1 fonts-liberation 2>/dev/null \
    || warn "Chrome 依赖可能不完整，gowitness 首次运行或需 playwright install"
  go_install_tool "github.com/sensepost/gowitness@latest" "gowitness" || return 1
  log "初始化 gowitness 浏览器依赖..."
  "${TOOLS_DIR}/bin/gowitness" install >> "$LOG_FILE" 2>&1 \
    || warn "gowitness install 失败，可手动: gowitness install"
  ok "  调用: gowitness scan file -f urls.txt --threads 20"
  ok "  报告: gowitness report generate"
}

# ───────────────────────── EHole (/root/git/Env) ─────────────────────────
install_ehole() {
  log "===== 安装 EHole (红队指纹) → ${ENV_DIR}/EHole ====="
  init_tools_dir
  ensure_go_env || return 1
  apt_install git || true

  local ehole_dir="${ENV_DIR}/EHole"
  if [ -x "${ehole_dir}/EHole" ] && sectools_should_skip; then
    ln -sf "${ehole_dir}/EHole" "${TOOLS_DIR}/bin/ehole" 2>/dev/null || true
    ok "EHole 已安装，跳过: ${ehole_dir}/EHole"
    return 0
  fi

  env_git_clone "https://github.com/EdgeSecurityTeam/EHole.git" "$ehole_dir" || return 1

  log "编译 EHole..."
  if ! (cd "$ehole_dir" && go build -o EHole . >> "$LOG_FILE" 2>&1); then
    err "EHole 编译失败，见 ${LOG_FILE}"
    return 1
  fi
  chmod +x "${ehole_dir}/EHole"
  ln -sf "${ehole_dir}/EHole" "${TOOLS_DIR}/bin/ehole"

  if [ ! -f "${ehole_dir}/config.ini" ]; then
    cat > "${ehole_dir}/config.ini" <<'EOF'
Email=
Fofa_token=
Fofa_timeout=10
EOF
    ok "已生成 ${ehole_dir}/config.ini（FOFA 模式需填 Email + Fofa_token）"
  fi

  zshrc_append "ehole" "alias ehole='${ehole_dir}/EHole'
alias cdehole='cd ${ehole_dir}'"

  ok "EHole 安装完成"
  ok "  本地指纹: ${ehole_dir}/EHole finger -l urls.txt -o result.json"
  ok "  FOFA 模式: 编辑 ${ehole_dir}/config.ini 后 EHole finger -f 192.168.1.0/24"
}

# ───────────────────────── URLFinder (/root/git/Env) ─────────────────────────
install_urlfinder() {
  log "===== 安装 URLFinder (JS/URL 提取) → ${ENV_DIR}/URLFinder ====="
  init_tools_dir
  ensure_go_env || return 1

  local uf_dir="${ENV_DIR}/URLFinder"
  if [ -x "${uf_dir}/URLFinder" ] && sectools_should_skip; then
    ln -sf "${uf_dir}/URLFinder" "${TOOLS_DIR}/bin/urlfinder" 2>/dev/null || true
    ok "URLFinder 已安装，跳过: ${uf_dir}/URLFinder"
    return 0
  fi

  env_git_clone "https://github.com/pingc0y/URLFinder.git" "$uf_dir" || return 1

  log "编译 URLFinder..."
  if ! (cd "$uf_dir" && CGO_ENABLED=0 go build -ldflags "-s -w" -o URLFinder . >> "$LOG_FILE" 2>&1); then
    err "URLFinder 编译失败，见 ${LOG_FILE}"
    return 1
  fi
  chmod +x "${uf_dir}/URLFinder"
  ln -sf "${uf_dir}/URLFinder" "${TOOLS_DIR}/bin/urlfinder"

  zshrc_append "urlfinder" "alias cdurlfinder='cd ${uf_dir}'"

  ok "URLFinder 安装完成"
  ok "  单 URL: urlfinder -u https://target.com -s 200,403 -m 3 -o ."
  ok "  批量:   urlfinder -f urls.txt -s all -m 3 -o ./out"
  ok "  配置:   首次 urlfinder -i 生成 ${uf_dir}/config.yaml"
}

# ───────────────────────── fav-up (/root/git/Env) ─────────────────────────
install_favup() {
  log "===== 安装 fav-up (Favicon→Shodan 真实IP) → ${ENV_DIR}/fav-up ====="
  init_tools_dir
  apt_install python3 python3-pip python3-venv git || warn "fav-up 依赖安装失败"

  local fav_dir="${ENV_DIR}/fav-up"
  if [ -x "${TOOLS_DIR}/bin/favup" ] \
     && [ -x "${fav_dir}/venv/bin/python" ] \
     && [ -f "${fav_dir}/favUp.py" ] \
     && sectools_should_skip; then
    ok "fav-up 已安装，跳过: ${fav_dir}"
    return 0
  fi

  env_git_clone "https://github.com/pielco11/fav-up.git" "$fav_dir" || return 1

  if [ -x "${fav_dir}/venv/bin/python" ] && sectools_should_skip; then
    ok "fav-up venv 已存在，跳过 pip 安装"
  else
  log "创建 Python 虚拟环境..."
  python3 -m venv "${fav_dir}/venv" >> "$LOG_FILE" 2>&1
  local pip_extra=""
  [ "$IS_CN" = "yes" ] && pip_extra="-i https://pypi.tuna.tsinghua.edu.cn/simple"
  "${fav_dir}/venv/bin/pip" install --upgrade pip $pip_extra >> "$LOG_FILE" 2>&1
  "${fav_dir}/venv/bin/pip" install -r "${fav_dir}/requirements.txt" $pip_extra >> "$LOG_FILE" 2>&1 \
    || { err "fav-up 依赖安装失败"; return 1; }
  fi

  cat > "${TOOLS_DIR}/bin/favup" <<EOF
#!/usr/bin/env bash
# fav-up 封装：需 Shodan API Key（-k / -kf / -sc）
exec "${fav_dir}/venv/bin/python" "${fav_dir}/favUp.py" "\$@"
EOF
  chmod +x "${TOOLS_DIR}/bin/favup"

  mkdir -p "${ENV_DIR}/.secrets"
  chmod 700 "${ENV_DIR}/.secrets"
  if [ ! -f "${ENV_DIR}/.secrets/shodan.key" ]; then
    touch "${ENV_DIR}/.secrets/shodan.key"
    chmod 600 "${ENV_DIR}/.secrets/shodan.key"
    ok "已创建 ${ENV_DIR}/.secrets/shodan.key（填入 Shodan API Key，一行）"
  fi

  zshrc_append "favup" "alias cdfavup='cd ${fav_dir}'
# fav-up 示例（Key 见 ${ENV_DIR}/.secrets/shodan.key）:
# favup --web target.com -kf ${ENV_DIR}/.secrets/shodan.key"

  ok "fav-up 安装完成"
  ok "  用法: favup --web target.com -kf ${ENV_DIR}/.secrets/shodan.key"
  ok "  或:   shodan init YOUR_KEY && favup --web target.com -sc"
}

# ───────────────────────── subfinder ─────────────────────────
install_subfinder() {
  log "===== 安装 subfinder (被动子域枚举) ====="
  init_tools_dir
  go_install_tool "github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest" "subfinder" || return 1
  ok "  调用: subfinder -d target.com -all -silent"
  ok "  API Key: ~/.config/subfinder/provider-config.yaml"
}

# ───────────────────────── amass ─────────────────────────
install_amass() {
  log "===== 安装 amass (子域枚举) ====="
  init_tools_dir
  go_install_tool "github.com/owasp-amass/amass/v4/cmd/amass@master" "amass" || return 1
  ok "  调用: amass enum -passive -d target.com"
  ok "  数据源: ~/.config/amass/config.ini 或 datasources.yaml"
}

# ───────────────────────── fscan ─────────────────────────
install_fscan() {
  log "===== 安装 fscan (端口扫描补充，shadow1ng/fscan) ====="
  init_tools_dir
  local existing
  existing=$(resolve_tool_bin fscan)
  if [ -n "$existing" ] && sectools_should_skip; then
    ln -sf "$existing" "${TOOLS_DIR}/bin/fscan" 2>/dev/null || true
    ok "fscan 已安装，跳过: $(tool_version_line "$existing")"
    return 0
  fi
  local ver="${FSCAN_VERSION:-2.1.3}"
  local url="https://github.com/shadow1ng/fscan/releases/download/v${ver}/fscan-nolocal_${ver}_linux_x64"
  local tmp="/tmp/fscan_dl_$$"
  log "下载 fscan v${ver}..."
  if ! curl -fsSL --max-time 120 "$url" -o "$tmp"; then
    err "fscan 下载失败: $url（可先 clash on）"
    rm -f "$tmp"
    return 1
  fi
  if ! file "$tmp" 2>/dev/null | grep -q ELF; then
    err "fscan 下载内容非 ELF 可执行文件"
    rm -f "$tmp"
    return 1
  fi
  install -m 0755 "$tmp" "${TOOLS_DIR}/bin/fscan"
  rm -f "$tmp"
  ok "fscan 安装完成"
  ok "  EASM: fscan -h <IP> -nobr -nopoc -o fscan_result.txt"
}

# ───────────────────────── ENScan (/root/git/Env) ─────────────────────────
install_enscan() {
  log "===== 安装 ENScan (企业信息/ICP) → ${ENV_DIR}/ENScan_GO ====="
  init_tools_dir
  local ens_dir="${ENV_DIR}/ENScan_GO"
  local tar="${ENV_DIR}/enscan-v2.0.5-linux-amd64.tar.gz"

  if [ -x "${ens_dir}/enscan" ] && sectools_should_skip; then
    ln -sf "${ens_dir}/enscan" "${TOOLS_DIR}/bin/enscan" 2>/dev/null || true
    ok "ENScan 已安装，跳过: ${ens_dir}/enscan"
    return 0
  fi

  mkdir -p "$ens_dir"
  if [ ! -f "$tar" ]; then
    err "未找到 ${tar}，请将 enscan-v2.0.5-linux-amd64.tar.gz 放到 ${ENV_DIR}/ 后重试"
    return 1
  fi

  log "解压 ENScan..."
  tar -xzf "$tar" -C "$ens_dir" >> "$LOG_FILE" 2>&1 || { err "ENScan 解压失败"; return 1; }
  if [ -f "${ens_dir}/enscan-v2.0.5-linux-amd64" ]; then
    mv -f "${ens_dir}/enscan-v2.0.5-linux-amd64" "${ens_dir}/enscan"
  fi
  chmod +x "${ens_dir}/enscan"
  ln -sf "${ens_dir}/enscan" "${TOOLS_DIR}/bin/enscan"

  if [ ! -f "${ens_dir}/config.yaml" ]; then
    (cd "$ens_dir" && ./enscan -v >> "$LOG_FILE" 2>&1) || true
    ok "已生成 ${ens_dir}/config.yaml（请填写 cookies.aiqicha 等）"
  fi

  zshrc_append "enscan" "alias enscli='${ens_dir}/enscan'
alias cdenscan='cd ${ens_dir}'"

  ok "ENScan 安装完成"
  ok "  ICP: enscan -n 公司名 -type aiqicha -field icp"
  ok "  Cookie: ${ens_dir}/config.yaml"
}

# ───────────────────────── uncover ─────────────────────────
# 定位 uncover provider-config 示例（CyberStrikeAI 仓库 / MyTools 副本）
resolve_uncover_example_path() {
  local d example
  for d in \
    "${CYBERSTRIKEAI_ROOT:-}" \
    "/root/git/CyberStrikeAI" \
    "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)" \
    "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/.."; do
    [ -z "$d" ] && continue
    for example in \
      "${d}/skills/easm-recon/references/uncover-provider-config.example.yaml" \
      "${d}/MyTools/references/uncover-provider-config.example.yaml"; do
      if [ -f "$example" ]; then
        echo "$example"
        return 0
      fi
    done
  done
  return 1
}

# 解析 CyberStrikeAI 根目录（用于从 config.yaml 同步 FOFA 等 Key）
resolve_csai_root() {
  local d
  for d in \
    "${CYBERSTRIKEAI_ROOT:-}" \
    "/root/git/CyberStrikeAI" \
    "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)"; do
    [ -n "$d" ] && [ -f "${d}/config.yaml" ] && echo "$d" && return 0
  done
  return 1
}

# 写入 ~/.config/uncover/provider-config.yaml（不存在或 YAML 损坏时从示例生成；可合并 env/config.yaml）
setup_uncover_provider_config() {
  local cfg_dir="${HOME}/.config/uncover"
  local prov="${cfg_dir}/provider-config.yaml"
  local example csai_root
  mkdir -p "$cfg_dir"

  example="$(resolve_uncover_example_path)" || {
    warn "未找到 uncover-provider-config.example.yaml，跳过 provider-config 写入"
    return 1
  }

  local need_seed=0
  if [ ! -f "$prov" ]; then
    need_seed=1
  elif ! python3 -c "import yaml; yaml.safe_load(open('${prov}'))" 2>/dev/null; then
    warn "现有 ${prov} YAML 无法解析，将备份后重新生成"
    cp -f "$prov" "${prov}.bak.$(date +%s)"
    need_seed=1
  fi

  if [ "$need_seed" -eq 1 ]; then
    cp -f "$example" "$prov"
    ok "  已写入 ${prov}（来自示例模板）"
  else
    ok "  保留已有 ${prov}（仅校验与补全 Key）"
  fi
  chmod 600 "$prov"

  csai_root="$(resolve_csai_root 2>/dev/null || true)"
  python3 - "$prov" "${csai_root:-}" <<'PY' >> "$LOG_FILE" 2>&1 || warn "provider-config Key 合并失败（见 ${LOG_FILE}）"
import os, re, sys
try:
    import yaml
except ImportError:
    sys.exit(0)

prov_path, csai_root = sys.argv[1], sys.argv[2] or ""
with open(prov_path, encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}
if not isinstance(data, dict):
    data = {}

PLACEHOLDER = re.compile(
    r"YOUR_|^your@|^example@|_API_KEY|_TOKEN|PLACEHOLDER|^GOOGLE_API|^NETLAS_API|^PUBLICWWW",
    re.I,
)

def is_placeholder(val):
    if not isinstance(val, str):
        return True
    s = val.strip()
    return (not s) or bool(PLACEHOLDER.search(s))

def section_all_placeholder(engine):
    keys = data.get(engine)
    if not isinstance(keys, list) or not keys:
        return True
    return all(is_placeholder(k) for k in keys)

def set_single(engine, value):
    if value and section_all_placeholder(engine):
        data[engine] = [value]

# 环境变量优先
set_single("fofa", f"{os.environ.get('FOFA_EMAIL', '').strip()}:{os.environ.get('FOFA_API_KEY', '').strip()}"
           if os.environ.get("FOFA_EMAIL") and os.environ.get("FOFA_API_KEY") else "")
set_single("hunter", os.environ.get("HUNTER_API_KEY", "").strip())
set_single("quake", os.environ.get("QUAKE_TOKEN", "").strip() or os.environ.get("QUAKE_API_KEY", "").strip())
set_single("shodan", os.environ.get("SHODAN_API_KEY", "").strip())
set_single("zoomeye", os.environ.get("ZOOMEYE_API_KEY", "").strip())

# 从 CyberStrikeAI config.yaml 补 FOFA（仅当 fofa 段仍为占位）
cfg = os.path.join(csai_root, "config.yaml") if csai_root else ""
if cfg and os.path.isfile(cfg) and section_all_placeholder("fofa"):
    try:
        with open(cfg, encoding="utf-8") as f:
            root = yaml.safe_load(f) or {}
        fofa = root.get("fofa") or {}
        email = str(fofa.get("email", "")).strip()
        api_key = str(fofa.get("api_key", "")).strip()
        if email and api_key and not is_placeholder(email) and not is_placeholder(api_key):
            data["fofa"] = [f"{email}:{api_key}"]
    except Exception:
        pass

with open(prov_path, "w", encoding="utf-8") as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
PY

  ok "  provider-config: ${prov}"
  return 0
}

# 校验 uncover provider-config：YAML 语法 + 各引擎 Key 是否仍为占位
check_uncover_provider_config() {
  local prov="${HOME}/.config/uncover/provider-config.yaml"
  if [ ! -f "$prov" ]; then
    warn "  未找到 ${prov}，请先运行 setup 或 -uncover"
    return 1
  fi
  if [ "$(stat -c '%a' "$prov" 2>/dev/null || stat -f '%OLp' "$prov" 2>/dev/null)" != "600" ]; then
    warn "  ${prov} 权限应为 600，正在修正"
    chmod 600 "$prov"
  fi

  local result rc=0
  result="$(python3 - "$prov" <<'PY'
import re, sys
try:
    import yaml
except ImportError:
    print("FAIL|缺少 python3-yaml，无法校验（可 apt install python3-yaml）")
    sys.exit(3)

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f)
except Exception as e:
    print(f"FAIL|YAML 解析失败: {e}")
    sys.exit(2)

if not isinstance(data, dict) or not data:
    print("FAIL|配置为空或格式错误（顶层应为 engine: [keys]）")
    sys.exit(2)

PLACEHOLDER = re.compile(
    r"YOUR_|^your@|^example@|_API_KEY_\d|_TOKEN_\d|_API_KEY$|_TOKEN$|PLACEHOLDER|^GOOGLE_API|^NETLAS_API|^PUBLICWWW|^CENSYS_API|^HUNTERHOW|^ONYPHE|^DRIFTNET|^DAYDAYMAP|^NERDYDATA",
    re.I,
)
EASM_CORE = ("hunter", "fofa", "quake")

ok_eng, warn_eng, bad_eng = [], [], []
for engine, keys in data.items():
    if str(engine).startswith("#"):
        continue
    if not isinstance(keys, list):
        bad_eng.append(f"{engine}(非列表)")
        continue
    valid = [k for k in keys if isinstance(k, str) and k.strip() and not PLACEHOLDER.search(k.strip())]
    ph = [k for k in keys if isinstance(k, str) and (not k.strip() or PLACEHOLDER.search(k.strip()))]
    if valid:
        ok_eng.append(f"{engine}×{len(valid)}")
    elif keys:
        warn_eng.append(engine)
    else:
        warn_eng.append(f"{engine}(空)")

core_ok = [e for e in EASM_CORE if any(x.startswith(e + "×") for x in ok_eng)]
lines = []
if ok_eng:
    lines.append("OK|" + ", ".join(ok_eng))
else:
    lines.append("WARN|没有任何引擎配置了有效 Key")
if warn_eng:
    lines.append("WARN|待填/占位(可选引擎): " + ", ".join(warn_eng))
if bad_eng:
    lines.append("FAIL|格式错误: " + ", ".join(bad_eng))
if not core_ok:
    lines.append("WARN|EASM 核心引擎(hunter/fofa/quake)均无有效 Key，ICP 反查可能失败")
print("\n".join(lines))
# 核心引擎至少一个有效即视为可用；仅可选引擎占位不算失败
sys.exit(0 if core_ok else 1)
PY
)" || rc=$?

  local line kind msg has_core_warn=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    kind="${line%%|*}"
    msg="${line#*|}"
    case "$kind" in
      OK)   ok "  uncover 配置: ${msg}" ;;
      WARN)
        warn "  uncover 配置: ${msg}"
        case "$msg" in
          *EASM\ 核心*) has_core_warn=1; rc=1 ;;
          *没有任何引擎*) has_core_warn=1; rc=1 ;;
        esac
        ;;
      FAIL) err "  uncover 配置: ${msg}"; rc=2 ;;
    esac
  done <<< "$result"

  if [ "$rc" -eq 0 ]; then
    ok "  uncover provider-config 校验通过（hunter/fofa/quake 至少一项已配置）"
  elif [ "$has_core_warn" -eq 1 ]; then
    warn "  请编辑 ${prov} 填入 hunter/fofa/quake Key（见 06-api-credentials.md）"
  fi
  return "$rc"
}

install_uncover() {
  log "===== 安装 uncover (多空间引擎 CLI: Hunter/FOFA/Quake 等) ====="
  init_tools_dir
  go_install_tool "github.com/projectdiscovery/uncover/cmd/uncover@latest" "uncover" || return 1
  setup_uncover_provider_config || warn "uncover provider-config 未就绪"
  check_uncover_provider_config || true
  ok "  Hunter ICP: uncover -e hunter -q 'icp.number=\"京ICP备XXXX号-8\"' -f host -silent"
  ok "  配置: ~/.config/uncover/provider-config.yaml"
  ok "  文档: skills/easm-recon/references/06-api-credentials.md"
}

# ───────────────────────── MCP 工具 apt 安装 (对齐 install-tools.sh) ─────────────────────────
resolve_install_tools_sh() {
  local csai_root installer
  csai_root="$(resolve_csai_root 2>/dev/null || true)"
  for installer in \
    "${DEFAULT_SCRIPT_PATH%/*}/install-tools.sh" \
    "/root/.1/install-tools.sh" \
    "${csai_root:+$csai_root/install-tools.sh}" \
    "/root/git/CyberStrikeAI/install-tools.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)/install-tools.sh"; do
    [ -n "$installer" ] && [ -f "$installer" ] && echo "$installer" && return 0
  done
  return 1
}

# install-tools.sh 映射表 apt 列去重（fallback；Ubuntu 无 Kali 包名时会跳过）
_mcp_apt_package_list() {
  cat <<'EOF'
amass arjun arp-scan binwalk checksec dalfox dirsearch dnsenum dotdotpwn
enum4linux-ng libimage-exiftool-perl feroxbuster ffuf fierce foremost gdb
gobuster hashcat hashpump hydra python3-impacket john jwt-tool kube-bench
libc-database masscan metasploit-framework nbtscan nikto nmap naabu binutils
one-gadget radare2 responder ropper samba-common-bin rustscan smbmap sqlmap
steghide subfinder terrascan trivy volatility3 wafw00f wpscan x8 xsser
nuclei jaeles katana zsteg falco ghidra xxd
EOF
}

# 内置 apt 批量安装（未找到 install-tools.sh 时使用）
install_mcp_apt_tools_native() {
  local pkg avail=() missing=() skipped=0
  apt_update || warn "apt-get update 失败"
  while read -r pkg; do
    [ -z "$pkg" ] && continue
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      avail+=("$pkg")
    else
      missing+=("$pkg")
      skipped=$((skipped + 1))
    fi
  done < <(_mcp_apt_package_list | tr ' ' '\n' | sort -u)

  [ "$skipped" -gt 0 ] && warn "Ubuntu 源不可用包 ${skipped} 个（多为 Kali 专用，已跳过）"
  if [ "${#avail[@]}" -eq 0 ]; then
    warn "当前 apt 源无可用 MCP 工具包"
    return 1
  fi
  log "apt 批量安装 MCP 工具 (${#avail[@]} 包)..."
  apt_install "${avail[@]}" \
    && ok "apt 批量安装完成 (${#avail[@]} 包)" \
    || warn "部分 apt 包安装失败，见 ${LOG_FILE}"
}

# 调用 install-tools.sh --method apt（与 CyberStrikeAI tools/*.yaml 映射一致）
install_mcp_apt_tools() {
  log "===== MCP 工具 apt 安装 (install-tools.sh --method apt) ====="
  local installer rc=0
  apt_update || warn "apt-get update 失败"

  installer="$(resolve_install_tools_sh 2>/dev/null || true)"
  if [ -n "$installer" ]; then
    export PATH="/usr/local/go/bin:${GOPATH:-/root/go}/bin:/usr/local/bin:${PATH}"
    log "执行: bash ${installer} --method apt"
    if bash "$installer" --method apt >> "$LOG_FILE" 2>&1; then
      ok "install-tools.sh --method apt 执行完成"
    else
      warn "install-tools.sh --method apt 部分失败（Ubuntu 无 Kali 包时正常），见 ${LOG_FILE}"
      rc=1
    fi
    check_mcp_apt_tools || true
    return "$rc"
  fi

  warn "未找到 install-tools.sh，使用内置 apt 包列表"
  install_mcp_apt_tools_native || rc=1
  return "$rc"
}

# 检查 MCP apt 工具就绪情况
check_mcp_apt_tools() {
  local installer summary
  echo ""
  echo -e "${C_YEL}── MCP apt 工具状态 (install-tools.sh) ──${C_NC}"
  installer="$(resolve_install_tools_sh 2>/dev/null || true)"
  if [ -n "$installer" ]; then
    summary="$(bash "$installer" --check 2>&1 | tee -a "$LOG_FILE")"
    echo "$summary" | grep -E '总计|已就绪|跳过|缺失|失败工具' | head -5
    echo "$summary" | sed -n '/失败工具:/,/^$/p' | head -20
    echo -e "  完整检查: ${C_YEL}bash ${installer} --check${C_NC}"
    echo -e "  仅 apt 安装: ${C_YEL}sudo bash ${SCRIPT_NAME} -mcp-apt${C_NC}"
    echo ""
    return 0
  fi
  warn "未找到 install-tools.sh，无法汇总 MCP 工具状态"
  echo -e "  同步脚本: ${C_YEL}sudo bash ${SCRIPT_NAME} -update-tools${C_NC}"
  echo ""
  return 1
}

# ───────────────────────── 所有安全工具一键安装 ─────────────────────────
install_sectools() {
  log "===== 安全工具套件（已安装则跳过，仅补装缺失项）====="
  print_sectools_catalog
  check_sectools_status
  install_scanners
  install_oneforall
  install_enscan
  install_nuclei
  install_subfinder
  install_amass
  install_httpx
  install_naabu
  install_dnsx
  install_shuffledns
  install_ehole
  install_urlfinder
  install_gowitness
  install_favup
  install_fscan
  install_uncover
  install_mcp_apt_tools || warn "MCP apt 工具部分未安装（Ubuntu 无 Kali 包时可忽略）"
  ok "安全工具套件处理完成"
  check_sectools_status
  ok "  目录: ${TOOLS_DIR}/bin + ${ENV_DIR}/"
  ok "  强制重装全部: SECTOOLS_FORCE=1 sudo bash ${SCRIPT_NAME} -sectools"
  ok "  API Key 配置见 CyberStrikeAI skills/easm-recon/references/06-api-credentials.md"
}

# ───────────────────────── DNS 修改（持久化公共 DNS）─────────────────────────
# 针对 Ubuntu 24 + systemd-resolved 的三层处理：
#   层1: /etc/systemd/resolved.conf  —— 全局 DNS，重启后依然生效
#   层2: netplan / NetworkManager    —— 禁止 DHCP 下发 DNS 覆盖全局设置
#   层3: /etc/resolv.conf            —— 确保指向 systemd-resolved stub
setup_dns() {
  log "===== 配置公共 DNS (8.8.8.8 / 1.1.1.1) ====="

  local dns_primary="8.8.8.8"
  local dns_secondary="1.1.1.1"
  local dns_fallback="9.9.9.9 8.8.4.4"

  # ── 层1: systemd-resolved 全局配置 ──────────────────────────
  log "层1: 修改 /etc/systemd/resolved.conf（全局 DNS）"
  local resolved_conf="/etc/systemd/resolved.conf"
  cp -f "$resolved_conf" "${resolved_conf}.bak.$(date +%s)"

  # 用 sed 替换已有项，grep 确认不存在才追加
  # [Resolve] 段
  if ! grep -q '^\[Resolve\]' "$resolved_conf"; then
    echo '[Resolve]' >> "$resolved_conf"
  fi

  # 批量写入关键字段（直接重写整个 [Resolve] 段，最干净）
  python3 - <<PYEOF
import re, pathlib

path = pathlib.Path("$resolved_conf")
content = path.read_text()

fields = {
    "DNS":         "${dns_primary} ${dns_secondary}",
    "FallbackDNS": "${dns_fallback}",
    "Domains":     "~.",          # ~. 让全部域名都走这里设置的 DNS
    "LLMNR":       "no",
    "MulticastDNS":"no",
    "DNSOverTLS":  "no",
    "DNSSEC":      "no",
    "Cache":       "yes",
    "DNSStubListener": "yes",
}

def set_field(text, key, value):
    pattern = rf'(?m)^#?\s*{key}\s*=.*$'
    replacement = f'{key}={value}'
    if re.search(pattern, text):
        return re.sub(pattern, replacement, text)
    # 追加到 [Resolve] 段后面
    return re.sub(r'(\[Resolve\])', rf'\1\n{replacement}', text)

for k, v in fields.items():
    content = set_field(content, k, v)

path.write_text(content)
print("resolved.conf 写入完成")
PYEOF

  ok "层1: resolved.conf 已更新"

  # ── 层2A: netplan —— 禁止每张网卡的 DHCP DNS 覆盖全局设置 ──
  log "层2: 检测并处理 netplan / NetworkManager 的每链路 DNS"
  local netplan_dir="/etc/netplan"
  local netplan_patched=0
  if [ -d "$netplan_dir" ] && ls "${netplan_dir}"/*.yaml 2>/dev/null | grep -q .; then
    log "检测到 netplan 配置，禁用 DHCP 自动推送 DNS..."
    for f in "${netplan_dir}"/*.yaml; do
      cp -f "$f" "${f}.bak.$(date +%s)"
      python3 - <<PYEOF
import yaml, sys, pathlib, copy

path = pathlib.Path("$f")
try:
    cfg = yaml.safe_load(path.read_text()) or {}
except Exception as e:
    print(f"WARN: 解析 {path} 失败: {e}", file=sys.stderr)
    sys.exit(0)

changed = False
for section in ("ethernets", "wifis", "vlans", "bonds", "bridges"):
    for iface, icfg in (cfg.get("network", {}).get(section, {}) or {}).items():
        if icfg is None:
            icfg = {}
            cfg["network"][section][iface] = icfg
        # 禁止 DHCP 推送 DNS
        dhcp4 = icfg.get("dhcp4-overrides", {}) or {}
        dhcp6 = icfg.get("dhcp6-overrides", {}) or {}
        if not dhcp4.get("use-dns") == False:
            dhcp4["use-dns"] = False
            icfg["dhcp4-overrides"] = dhcp4
            changed = True
        if not dhcp6.get("use-dns") == False:
            dhcp6["use-dns"] = False
            icfg["dhcp6-overrides"] = dhcp6
            changed = True
        # 明确指定 nameservers（让 netplan 也知道用公共 DNS）
        icfg["nameservers"] = {
            "addresses": ["${dns_primary}", "${dns_secondary}"]
        }
        changed = True

if changed:
    path.write_text(yaml.dump(cfg, default_flow_style=False, allow_unicode=True))
    print(f"  已更新: {path}")
else:
    print(f"  无需修改: {path}")
PYEOF
    done
    # 安装 python3-yaml 如果没有
    python3 -c "import yaml" 2>/dev/null || apt_install python3-yaml || true
    netplan apply >> "$LOG_FILE" 2>&1 && ok "netplan apply 完成" || warn "netplan apply 失败，继续..."
    netplan_patched=1
  fi

  # ── 层2B: NetworkManager —— 对每个连接禁用 DHCP DNS ──
  if command -v nmcli >/dev/null 2>&1; then
    log "检测到 NetworkManager，对所有连接禁用 DHCP DNS 推送..."
    nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | while IFS=: read -r name type; do
      [ -z "$name" ] && continue
      nmcli connection modify "$name" ipv4.ignore-auto-dns yes   >> "$LOG_FILE" 2>&1 || true
      nmcli connection modify "$name" ipv6.ignore-auto-dns yes   >> "$LOG_FILE" 2>&1 || true
      nmcli connection modify "$name" ipv4.dns "${dns_primary} ${dns_secondary}" >> "$LOG_FILE" 2>&1 || true
      ok "NM 连接已更新: ${name}"
    done
    nmcli general reload >> "$LOG_FILE" 2>&1 || true
  fi

  # ── 层3: /etc/resolv.conf —— 确保指向 systemd-resolved stub ──
  log "层3: 确保 /etc/resolv.conf -> systemd-resolved stub (127.0.0.53)"
  # Ubuntu 24 正常情况下 resolv.conf 是软链接到 stub，这里强制修正
  if [ ! -L /etc/resolv.conf ] || [ "$(readlink /etc/resolv.conf)" != "../run/systemd/resolve/stub-resolv.conf" ]; then
    rm -f /etc/resolv.conf
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    ok "已重建软链接: /etc/resolv.conf -> stub-resolv.conf"
  else
    ok "/etc/resolv.conf 软链接正常"
  fi

  # ── 重启 systemd-resolved 使配置生效 ──
  log "重启 systemd-resolved..."
  systemctl restart systemd-resolved >> "$LOG_FILE" 2>&1
  sleep 2

  # ── 验证当前 DNS 配置 ──
  log "当前 DNS 状态:"
  resolvectl status 2>/dev/null | grep -E "DNS Server|Fallback|Current DNS" | \
    while read -r line; do echo "    ${line}"; done

  # ── 测试 DNS 解析和实际连通性 ──
  log "DNS 解析测试（nslookup）:"
  if command -v nslookup >/dev/null 2>&1; then
    nslookup downloads.cursor.com 2>&1 | grep -E "Server|Address|Name" | \
      while read -r line; do echo "    ${line}"; done
  else
    apt_install dnsutils || true
    nslookup downloads.cursor.com 2>&1 | grep -E "Server|Address|Name" | \
      while read -r line; do echo "    ${line}"; done
  fi

  log "实际连通性测试（curl -4 downloads.cursor.com）:"
  local http_code
  http_code=$(curl -4 -s --connect-timeout 10 -o /dev/null \
    -w "%{http_code} | IP:%{remote_ip} | 耗时:%{time_total}s" \
    https://downloads.cursor.com 2>&1)
  local curl_exit=$?
  if [ $curl_exit -eq 0 ]; then
    ok "curl 测试通过: ${http_code}"
  else
    warn "curl 测试返回码: ${curl_exit}（${http_code}）"
    warn "DNS 解析可能需要几秒稳定，可稍后手动执行:"
    warn "  curl -4 -v --connect-timeout 10 https://downloads.cursor.com"
  fi

  ok "DNS 配置完成，公共 DNS 已永久生效（重启后不会恢复 VPS 商内网 DNS）"
}

# ───────────────────────── SSH 远程登录（密码 + 公钥，含 Cursor 指引）─────────────────────────
# 终端输出统一 UTF-8，便于 Web/IDE 前端正确显示中文
ensure_utf8_output() {
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-C.UTF-8}"
  if ! locale -a 2>/dev/null | grep -qiE 'utf-?8'; then
    apt_install locales >/dev/null 2>&1 || true
    locale-gen en_US.UTF-8 2>/dev/null || true
    update-locale LANG=en_US.UTF-8 2>/dev/null || true
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
  fi
}

# 校验并追加客户端公钥到 authorized_keys（非服务器自身公钥）
ssh_append_authorized_key() {
  local key="$1"
  local auth="${HOME}/.ssh/authorized_keys"
  key="$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$key" ] && { warn "公钥为空，已跳过"; return 1; }
  if ! echo "$key" | grep -qE '^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-)'; then
    err "公钥格式无效（应以 ssh-ed25519 / ssh-rsa 等开头）"
    return 1
  fi
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  touch "$auth"
  chmod 600 "$auth"
  if grep -qF "$key" "$auth" 2>/dev/null; then
    ok "公钥已存在于 authorized_keys，无需重复添加"
    return 0
  fi
  echo "$key" >> "$auth"
  chmod 600 "$auth"
  ok "已追加客户端公钥到 ${auth}"
  return 0
}

# 从文件读取公钥并追加（文件可在服务器任意路径）
ssh_append_authorized_key_file() {
  local f="$1"
  [ -f "$f" ] || { err "公钥文件不存在: $f"; return 1; }
  ssh_append_authorized_key "$(head -1 "$f")"
}

# 检测 authorized_keys 是否误填了「服务器自身」公钥
ssh_warn_if_server_key_in_authorized() {
  local auth="${HOME}/.ssh/authorized_keys"
  local srv_pub="${HOME}/.ssh/id_ed25519.pub"
  [ -f "$auth" ] && [ -f "$srv_pub" ] || return 0
  if grep -qF "$(head -1 "$srv_pub")" "$auth" 2>/dev/null; then
    warn "authorized_keys 中含有「服务器自身」公钥，不能用于本机→VPS 免密登录"
    warn "请追加您本机（Mac/PC）的 ~/.ssh/id_ed25519.pub 内容，而非服务器上的公钥"
  fi
}

# 写入 sshd：同时允许密码登录与公钥登录
ssh_apply_sshd_config() {
  local dropin="/etc/ssh/sshd_config.d/99-vps-auto-login.conf"
  local main_cfg="/etc/ssh/sshd_config"
  mkdir -p /etc/ssh/sshd_config.d
  cat > "$dropin" <<'EOF'
# 由 vps_auto_work_cc.sh -ssh 管理
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitRootLogin yes
AuthorizedKeysFile .ssh/authorized_keys
AcceptEnv LANG LC_*
EOF
  chmod 644 "$dropin"
  ok "已写入 ${dropin}"

  # 覆盖 cloud-init 等 drop-in 可能禁用的密码登录（Match all 优先级更高）
  if ! grep -q 'vps_auto -ssh' "$main_cfg" 2>/dev/null; then
    cat >> "$main_cfg" <<'EOF'

# >>> vps_auto -ssh >>>
Match all
    PubkeyAuthentication yes
    PasswordAuthentication yes
    PermitRootLogin yes
# <<< vps_auto -ssh <<<
EOF
    ok "已在 sshd_config 末尾追加 Match all（密码+公钥双开）"
  else
    ok "sshd_config 已含 vps_auto -ssh 配置，跳过重复追加"
  fi

  # 若 cloud-init 显式关闭密码，改为 yes
  local cloud_init="/etc/ssh/sshd_config.d/50-cloud-init.conf"
  if [ -f "$cloud_init" ] && grep -qE '^\s*PasswordAuthentication\s+no' "$cloud_init"; then
    sed -i -E 's/^\s*PasswordAuthentication\s+no/PasswordAuthentication yes/' "$cloud_init"
    warn "已将 ${cloud_init} 中 PasswordAuthentication 改为 yes"
  fi

  if ! sshd -t 2>>"$LOG_FILE"; then
    err "sshd 配置校验失败，请检查 ${dropin} 与 ${main_cfg}"
    return 1
  fi
  systemctl restart ssh >> "$LOG_FILE" 2>&1 || systemctl restart sshd >> "$LOG_FILE" 2>&1 \
    || { err "ssh 服务重启失败"; return 1; }
  ok "sshd 配置校验通过，已重启 ssh 服务"
  return 0
}

# 检查 SSH 登录相关状态
check_ssh_login() {
  ensure_utf8_output
  echo ""
  echo -e "${C_YEL}── SSH 远程登录状态 ──${C_NC}"
  local auth="${HOME}/.ssh/authorized_keys"
  if systemctl is-active ssh >/dev/null 2>&1 || systemctl is-active sshd >/dev/null 2>&1; then
    ok "  ssh 服务: 运行中"
  else
    warn "  ssh 服务: 未运行"
  fi
  if [ -d "${HOME}/.ssh" ]; then
    ok "  ~/.ssh 权限: $(stat -c '%a' "${HOME}/.ssh" 2>/dev/null || echo '?')"
  else
    warn "  ~/.ssh 不存在"
  fi
  if [ -f "$auth" ]; then
    ok "  authorized_keys: $(wc -l < "$auth" | tr -d ' ') 条"
  else
    warn "  authorized_keys 不存在（仅密码登录可用）"
  fi
  grep -E '^(PubkeyAuthentication|PasswordAuthentication|PermitRootLogin)' \
    /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | head -10 \
    | while read -r line; do echo -e "  ${line}"; done
  ssh_warn_if_server_key_in_authorized
  echo ""
}

# 配置完成后输出 Cursor Remote SSH 操作指引（UTF-8）
print_cursor_ssh_guide() {
  get_public_ip
  local host="${PUBLIC_IP:-你的VPS公网IP}"
  local user="${SUDO_USER:-root}"
  [ "$(id -u)" -eq 0 ] && user="root"
  local hn
  hn="$(hostname -f 2>/dev/null || hostname)"

  cat <<EOF

════════════════════════════════════════════════════════════
  Cursor Remote SSH 连接指引（请在您的本机按下列步骤操作）
════════════════════════════════════════════════════════════

【当前服务器信息】
  公网 IP  : ${host}
  主机名   : ${hn}
  登录用户 : ${user}
  SSH 端口 : 22
  认证方式 : 密码登录 ✅  |  公钥免密 ✅（authorized_keys 已配置时）

────────────────────────────────────────────────────────────
步骤 1 — 在本机（Mac / Windows / Linux）生成密钥（若还没有）
────────────────────────────────────────────────────────────
  ssh-keygen -t ed25519 -C "cursor-${hn}" -f ~/.ssh/id_ed25519

────────────────────────────────────────────────────────────
步骤 2 — 将「本机公钥」上传到本 VPS（在本机终端执行）
────────────────────────────────────────────────────────────
  方式 A（推荐）:
    ssh-copy-id -i ~/.ssh/id_ed25519.pub ${user}@${host}

  方式 B（手动）:
    cat ~/.ssh/id_ed25519.pub
    # 复制整行输出，在 VPS 上执行:
    echo '粘贴您的本机公钥整行' >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys

  ⚠️  注意: 必须使用「您本机」的公钥，不是服务器 /root/.ssh/id_ed25519.pub

────────────────────────────────────────────────────────────
步骤 3 — 在本机 ~/.ssh/config 添加 Host（便于 Cursor 选择）
────────────────────────────────────────────────────────────
  Host cursor-vps
      HostName ${host}
      User ${user}
      Port 22
      IdentityFile ~/.ssh/id_ed25519
      ServerAliveInterval 60
      ServerAliveCountMax 3

────────────────────────────────────────────────────────────
步骤 4 — 在 Cursor 中连接
────────────────────────────────────────────────────────────
  1. 打开 Cursor
  2. 按 Cmd+Shift+P（Mac）或 Ctrl+Shift+P（Windows/Linux）
  3. 输入并选择: Remote-SSH: Connect to Host...
  4. 选择 cursor-vps 或输入 ${user}@${host}
  5. 首次连接:
     - 若已配置公钥 → 直接免密进入
     - 若未配置公钥 → 输入 VPS 密码即可
  6. 平台选择: Linux
  7. 打开文件夹: /root/git/CyberStrikeAI（或您的工作目录）

────────────────────────────────────────────────────────────
步骤 5 — 验证（在本机终端）
────────────────────────────────────────────────────────────
  ssh cursor-vps
  # 或
  ssh ${user}@${host}

  再次检查服务器 SSH 状态:
    sudo bash ${SCRIPT_NAME} -ssh-check

════════════════════════════════════════════════════════════

EOF
}

# 一键配置 SSH：openssh-server + 双认证 + 可选追加公钥
setup_ssh_login() {
  local key_arg="${1:-}"
  ensure_utf8_output
  log "===== 配置 SSH 远程登录（密码 + 公钥）====="
  apt_update || warn "apt-get update 失败"
  apt_install openssh-server || { err "openssh-server 安装失败"; return 1; }

  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  touch "${HOME}/.ssh/authorized_keys"
  chmod 600 "${HOME}/.ssh/authorized_keys"

  if [ ! -f "${HOME}/.ssh/id_ed25519" ]; then
    ssh-keygen -t ed25519 -N "" -f "${HOME}/.ssh/id_ed25519" \
      -C "${USER}@$(hostname)" >> "$LOG_FILE" 2>&1 \
      && ok "已生成服务器主机密钥 ~/.ssh/id_ed25519（供服务器对外连接用，非 Cursor 免密）"
  else
    ok "服务器主机密钥已存在 ~/.ssh/id_ed25519，跳过重新生成（重复执行 -ssh 不会冲突）"
  fi

  ssh_apply_sshd_config || return 1
  ssh_warn_if_server_key_in_authorized

  # 追加公钥：参数为文件路径或公钥字符串
  if [ -n "$key_arg" ]; then
    if [ -f "$key_arg" ]; then
      ssh_append_authorized_key_file "$key_arg"
    else
      ssh_append_authorized_key "$key_arg"
    fi
  else
    if [ -t 0 ]; then
      read -r -p "是否现在追加「本机客户端」SSH 公钥到 authorized_keys？(y/N): " add_key
      if [[ "$add_key" =~ ^[Yy]$ ]]; then
        read -r -p "请粘贴公钥整行（ssh-ed25519 AAAA... comment）: " pubkey
        ssh_append_authorized_key "$pubkey" || true
      else
        ok "已跳过公钥追加，您仍可使用密码登录；免密请按下方 Cursor 指引在本机执行 ssh-copy-id"
      fi
    else
      ok "非交互模式：未追加公钥。请在本机执行 ssh-copy-id 或: sudo bash ${SCRIPT_NAME} -ssh /path/to/your.pub"
    fi
  fi

  check_ssh_login
  print_cursor_ssh_guide
  ok "SSH 远程登录配置完成"
}

# ───────────────────────── PVE 虚拟机客户机依赖 ─────────────────────────
setup_pve_guest() {
  log "===== PVE 虚拟机客户机依赖（cloud-init / qemu-guest-agent / SSH）====="
  maybe_setup_apt_mirror_cn || true
  apt_update || warn "apt-get update 失败"
  apt_install cloud-init qemu-guest-agent openssh-server || return 1
  if systemctl list-unit-files qemu-guest-agent.service >/dev/null 2>&1; then
    systemctl enable qemu-guest-agent >> "$LOG_FILE" 2>&1 || true
    systemctl restart qemu-guest-agent >> "$LOG_FILE" 2>&1 || true
    ok "qemu-guest-agent 已启用"
  else
    warn "未找到 qemu-guest-agent.service"
  fi
  if command -v cloud-init >/dev/null 2>&1; then
    ok "cloud-init: $(cloud-init --version 2>&1 | head -1)"
  fi
  setup_ssh_login "${1:-}"
  ok "PVE 客户机初始化完成"
}

# ───────────────────────── 自更新（公开仓 alpha302/vps-auto）─────────────────────────
load_update_config() {
  UPDATE_MANIFEST_URL_EFFECTIVE="$UPDATE_MANIFEST_URL"
  UPDATE_INSTALL_PATH=""
  if [ -f "$UPDATE_CONFIG" ]; then
    # shellcheck source=/dev/null
    . "$UPDATE_CONFIG"
    [ -n "${MANIFEST_URL:-}" ] && UPDATE_MANIFEST_URL_EFFECTIVE="$MANIFEST_URL"
    [ -n "${INSTALL_PATH:-}" ] && UPDATE_INSTALL_PATH="$INSTALL_PATH"
  fi
}

resolve_script_path() {
  load_update_config
  local p="${UPDATE_INSTALL_PATH:-$DEFAULT_SCRIPT_PATH}"
  if [ -f "$p" ]; then
    echo "$p"
    return 0
  fi
  if [ -f "$DEFAULT_SCRIPT_PATH" ]; then
    echo "$DEFAULT_SCRIPT_PATH"
    return 0
  fi
  readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0"
}

resolve_update_base_raw() {
  load_update_config
  echo "${UPDATE_BASE_RAW:-https://raw.githubusercontent.com/alpha302/vps-auto/main}"
}

# 从公开仓同步 install-tools.sh / install.sh 到 /root/.1/
sync_companion_scripts() {
  local base dir f url dest
  base="$(resolve_update_base_raw)"
  dir="${DEFAULT_INSTALL_DIR}"
  mkdir -p "$dir"
  for f in install-tools.sh install.sh; do
    url="${base}/${f}"
    dest="${dir}/${f}"
    log "同步 companion: ${f} ..."
    if ! run_without_proxy curl -fsSL --max-time 120 "$url" -o "${dest}.new" >> "$LOG_FILE" 2>&1; then
      warn "下载失败: ${url}"
      rm -f "${dest}.new"
      continue
    fi
    if ! bash -n "${dest}.new" 2>>"$LOG_FILE"; then
      warn "${f} 语法检查失败 (bash -n)，未替换"
      rm -f "${dest}.new"
      continue
    fi
    if [ -f "$dest" ]; then
      cp -a "$dest" "${dest}.bak.$(date +%Y%m%d%H%M%S)"
    fi
    install -m 755 "${dest}.new" "$dest"
    rm -f "${dest}.new"
    ok "已同步: ${dest}"
  done
}

fetch_update_manifest() {
  load_update_config
  local url="$UPDATE_MANIFEST_URL_EFFECTIVE"
  local manifest
  manifest=$(run_without_proxy curl -fsSL --max-time 30 "$url" 2>/dev/null) || {
    err_err "无法拉取更新清单: ${url}"
    warn_err "若已开启 clash 代理，可先执行: noproxy  或  sudo bash ${SCRIPT_NAME} -noproxy"
    return 1
  }
  [ -n "$manifest" ] || { err_err "更新清单为空"; return 1; }
  echo "$manifest"
}

parse_manifest_field() {
  local json="$1" key="$2"
  echo "$json" | grep -oP "\"${key}\"\\s*:\\s*\"\\K[^\"]+" | head -1
}

version_gt() {
  local a="$1" b="$2"
  [ "$a" = "$b" ] && return 1
  local IFS=.
  local -a av bv
  read -ra av <<< "$a"
  read -ra bv <<< "$b"
  local i max=${#av[@]}
  [ ${#bv[@]} -gt "$max" ] && max=${#bv[@]}
  for ((i = 0; i < max; i++)); do
    local x=${av[i]:-0} y=${bv[i]:-0}
    if ((10#$x > 10#$y)); then return 0; fi
    if ((10#$x < 10#$y)); then return 1; fi
  done
  return 1
}

check_for_update() {
  ensure_utf8_output
  local manifest remote_ver remote_sha script_url changelog released_at
  manifest=$(fetch_update_manifest) || return 1
  remote_ver=$(parse_manifest_field "$manifest" version)
  remote_sha=$(parse_manifest_field "$manifest" sha256)
  script_url=$(parse_manifest_field "$manifest" script_url)
  changelog=$(parse_manifest_field "$manifest" changelog)
  released_at=$(parse_manifest_field "$manifest" released_at)
  [ -n "$remote_ver" ] || { err "更新清单缺少 version 字段"; return 1; }

  log "本地版本: ${SCRIPT_VERSION}"
  log "远程版本: ${remote_ver}  (${released_at:-未知时间})"
  [ -n "$changelog" ] && log "更新说明: ${changelog}"
  [ -n "$script_url" ] && log "脚本地址: ${script_url}"
  [ -n "$remote_sha" ] && log "SHA256: ${remote_sha}"

  if version_gt "$remote_ver" "$SCRIPT_VERSION"; then
    ok "发现新版本 ${remote_ver}，执行更新: sudo bash $(resolve_script_path) -update"
    return 0
  fi
  if [ "$remote_ver" = "$SCRIPT_VERSION" ]; then
    ok "已是最新版本 (${SCRIPT_VERSION})"
    return 0
  fi
  warn "本地版本 (${SCRIPT_VERSION}) 高于远程 (${remote_ver})，可能为开发版或未发布"
  return 0
}

perform_update() {
  require_root
  ensure_utf8_output
  touch "$LOG_FILE"

  local manifest remote_ver remote_sha script_url target tmpdir new_script checksum_file backup
  manifest=$(fetch_update_manifest) || return 1
  remote_ver=$(parse_manifest_field "$manifest" version)
  remote_sha=$(parse_manifest_field "$manifest" sha256)
  script_url=$(parse_manifest_field "$manifest" script_url)
  [ -n "$remote_ver" ] && [ -n "$script_url" ] || { err "更新清单缺少 version 或 script_url"; return 1; }

  if ! version_gt "$remote_ver" "$SCRIPT_VERSION" && [ "$remote_ver" != "$SCRIPT_VERSION" ]; then
    warn "远程版本 (${remote_ver}) 低于本地 (${SCRIPT_VERSION})，跳过更新"
    return 1
  fi
  if [ "$remote_ver" = "$SCRIPT_VERSION" ]; then
    ok "已是最新版本 (${SCRIPT_VERSION})，同步 companion 脚本..."
    sync_companion_scripts
    return 0
  fi

  target=$(resolve_script_path)
  tmpdir=$(mktemp -d /tmp/vps_auto_update.XXXXXX)
  new_script="${tmpdir}/vps_auto_work_cc.sh"
  checksum_file="${tmpdir}/sha256sum.txt"

  log "下载 v${remote_ver} ..."
  run_without_proxy curl -fsSL --max-time 120 "$script_url" -o "$new_script" >> "$LOG_FILE" 2>&1 || {
    err "下载失败: ${script_url}"
    rm -rf "$tmpdir"
    return 1
  }

  if ! bash -n "$new_script" 2>>"$LOG_FILE"; then
    err "新脚本语法检查失败 (bash -n)，未替换本地文件"
    rm -rf "$tmpdir"
    return 1
  fi

  if [ -n "$remote_sha" ]; then
    echo "${remote_sha}  ${new_script}" > "$checksum_file"
    if ! sha256sum -c "$checksum_file" >> "$LOG_FILE" 2>&1; then
      err "SHA256 校验失败，未替换本地文件"
      rm -rf "$tmpdir"
      return 1
    fi
    ok "SHA256 校验通过"
  else
    warn "更新清单未提供 sha256，已跳过校验（不推荐）"
  fi

  mkdir -p "$(dirname "$target")"
  if [ -f "$target" ]; then
    backup="${target}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$target" "$backup"
    ok "已备份旧版本: ${backup}"
  fi

  install -m 755 "$new_script" "$target"
  rm -rf "$tmpdir"
  ok "已更新至 v${remote_ver}: ${target}"
  sync_companion_scripts
  ok "请重新运行: sudo bash ${target} -h"
}

print_usage() {
  cat <<EOF
用法: sudo bash ${SCRIPT_NAME} [选项]          (版本 ${SCRIPT_VERSION})

  ── 地区/镜像策略 ───────────────────────────────────────────
  -region cn        手动设为国内镜像源（写入 ${REGION_CONFIG}）
  -region overseas  手动设为海外/官方源
  -region auto      重新自动检测并确认（覆盖缓存）

  首次运行会自动检测并询问确认；之后默认读取缓存，-h 不触发检测。

  ── 基础环境 ────────────────────────────────────────────────
  -all        依次执行: 时间同步(上海时区)/zsh/swap/docker/pip/java/go/scan/beauty/noproxy/流量统计
              国内环境会自动检测 Ubuntu 官方 apt 源并替换为阿里云镜像（22/24）
              运行时会交互询问地区（含香港/港澳台选项），不安装 clash
              （clash 需确认海外环境后单独执行 -clash）
  -zsh        安装并配置 zsh + oh-my-zsh + 插件 + 彩色终端
  -swap       创建 swap（按物理内存分档计算；/swapfile 偏小时自动重建，写入 fstab）
  -docker     安装 docker-ce（适配 20.04/22.04/24.04；自动卸载 docker.io 冲突包）
  -pip        配置 pip 源 + 解除 PEP668 system 限制
  -java       安装 Oracle JDK 8（国内用华为云镜像）
  -go         安装 Golang（国内自动切换 goproxy）
  -beauty     终端美化/主机名/去除登录提示/显示公网IP
  -time        设置 Asia/Shanghai + chrony NTP；执行时显示同步状态/系统时间/RTC/tracking/sources
  -time-check  仅查看上述时间/NTP 状态（不修改配置）
  -traffic     安装 vnstat+nethogs，启用历史流量统计并显示进程流量 TOP
  -traffic-check  仅查看 vnstat 历史累计 + nethogs 进程采样（不安装）
  -noproxy     关闭所有代理（停止 mihomo + 清除代理变量）并写入 noproxy 命令
  -dns        修改 DNS 为 8.8.8.8/1.1.1.1（三层持久化，
              覆盖 VPS 商内网 DNS，并测试连通性）
  -ssh [公钥文件或公钥字符串]
              配置 SSH：密码+公钥双开，修复权限，可选追加客户端公钥
              完成后 UTF-8 输出 Cursor Remote SSH 连接指引
  -ssh-check  查看 SSH 服务与 authorized_keys 状态（不修改配置）

  ── 安全工具（EASM 外部攻击面，对齐 easm-recon skill）──────
  -sectools       安装全套安全工具（已安装则跳过，只补缺失项）
  -sectools-check  仅查看安全工具安装状态（按六大类分组显示）
  -sectools-help   打印安全工具分类说明与推荐流程（不安装）

  ① 信息收集: -oneforall -subfinder -amass -enscan -uncover
  ② DNS:       -dnsx -shuffledns
  ③ 探活指纹:  -httpx -ehole -urlfinder -gowitness
  ④ 端口扫描:  -scan -naabu -fscan
  ⑤ CDN穿透:   -favup
  ⑥ 漏洞扫描:  -nuclei（可选，需授权）

  -scan       安装 masscan、nmap
  -oneforall  安装 OneForAll（子域名枚举，自动配置 venv）
  -enscan     安装 ENScan（企业/ICP，需 ${ENV_DIR}/enscan-v2.0.5-linux-amd64.tar.gz）
  -subfinder  安装 subfinder（被动子域枚举，go install）
  -amass      安装 amass（子域枚举，go install）
  -nuclei     安装 Nuclei + nuclei-templates（漏洞扫描）
  -httpx      安装 httpx（HTTP 探活/指纹，go install）
  -naabu      安装 naabu（端口扫描，需 libpcap-dev）
  -dnsx       安装 dnsx（DNS 解析/验证/爆破，go install）
  -shuffledns 安装 shuffledns（子域爆破，依赖 massdns）
  -ehole      安装 EHole → ${ENV_DIR}/EHole（红队指纹）
  -urlfinder  安装 URLFinder → ${ENV_DIR}/URLFinder（JS/URL 提取）
  -gowitness  安装 gowitness（Web 截图）
  -favup      安装 fav-up → ${ENV_DIR}/fav-up（Favicon+Shodan 找真实IP）
  -fscan      安装 fscan（端口扫描补充，EASM 用 -nobr -nopoc）
  -uncover    安装 uncover（Hunter/FOFA/Quake 等空间引擎 CLI，go install）
  -mcp-apt     安装 CyberStrikeAI MCP 工具中 apt 可提供的部分（调用 install-tools.sh --method apt）
  -mcp-apt-check  仅查看 MCP 工具 install-tools.sh --check 状态
  -update-tools  从公开仓同步 install-tools.sh + install.sh 到 ${DEFAULT_INSTALL_DIR}/

  ── PVE 虚拟机客户机 ─────────────────────────────────────────
  -pve [公钥文件或公钥字符串]
              安装 cloud-init + qemu-guest-agent，并配置 SSH 公钥+root 密码登录

  ── 其他 ────────────────────────────────────────────────────
  -clash      安装 mihomo 并指定 clash 配置文件（yaml 路径或订阅 URL）
  -cnvd-vpn [用户 密码]
              安装 CNVD 众测 OpenVPN（HTTP/HTTPS 策略路由 cnvdvpn on / 全流量 full）+ zshrc
              安装时可交互输入账号密码；也可传参或环境变量 CNVD_VPN_USER / CNVD_VPN_PASS
  -bugbox-vpn [用户 密码]
              安装 Bugbox OpenVPN（与 cnvdvpn 同级，bugboxvpn on/off/test）+ zshrc
              默认读取 ~/.1/client.ovpn；也可环境变量 BUGBOX_VPN_OVPN / BUGBOX_VPN_USER / BUGBOX_VPN_PASS
  -task-vpn [ovpn路径]
              安装腾讯云任务 OpenVPN（证书认证，taskvpn on/off/test）+ zshrc
              默认 ~/.1/task_g3oS99An9R5_vpn_config.ovpn；也可 TASK_VPN_OVPN 或传参指定
  -clash-harden  加固现有 mihomo 配置（禁止公网开放代理，防 CPU 打满）
              例: -clash /root/my-clash.yaml
              再次运行不带参数将复用上次配置；带新路径则更换配置
  -update-check  检查公开仓 alpha302/vps-auto 是否有新版本（不修改本地文件）
  -update        从公开仓下载并更新本脚本（bash -n + SHA256 校验，自动备份旧版）
              同时同步 install-tools.sh / install.sh 到 ${DEFAULT_INSTALL_DIR}/
  -remove     卸载所有云厂商监控 agent（阿里云/腾讯云/华为云/百度云通用）
  -aliyun     阿里云 ECS 专项清理（先预扫描，确认后清理，覆盖以下组件）
              · 云监控 CloudMonitor / ArgusAgent
              · 安骑士 / 云安全中心 Aegis
              · 云助手 ECS Assist（控制台远程命令通道）
              · ilogtail SLS 日志采集器
              · cron / systemd / rc.local 残留启动项
  -h          查看本帮助（不执行地区检测）
EOF
}

# 不需要地区镜像策略的命令（无需 root 的已在 main 提前处理）
needs_region() {
  case "${1:-}" in
    -h|--help|-region|""|-remove|-aliyun|-dns|-time|-time-check|-traffic-check|-update-check|-update|-update-tools|-noproxy) return 1 ;;
    # 安全工具安装不依赖镜像源选择，跳过地区交互
    -sectools|-sectools-check|-sectools-help|-scan|-oneforall|-enscan|-subfinder|-amass|-nuclei|-httpx|-naabu|-dnsx|-shuffledns|-ehole|-urlfinder|-gowitness|-favup|-fscan|-uncover|-mcp-apt|-mcp-apt-check|-ssh|-ssh-check|-clash-harden|-cnvd-vpn|-bugbox-vpn|-task-vpn) return 1 ;;
    *) return 0 ;;
  esac
}

main() {
  local cmd="${1:-}"

  # 帮助类命令：不检测地区、不要求 root
  case "$cmd" in
    -h|--help)
      print_usage
      exit 0
      ;;
    -ssh-check)
      touch "$LOG_FILE" 2>/dev/null || true
      ensure_utf8_output
      check_ssh_login
      print_cursor_ssh_guide
      exit 0
      ;;
    -time-check)
      touch "$LOG_FILE" 2>/dev/null || true
      ensure_utf8_output
      print_time_sync_status "当前 · 时间/NTP 状态"
      exit 0
      ;;
    -traffic-check)
      touch "$LOG_FILE" 2>/dev/null || true
      ensure_utf8_output
      print_traffic_status "当前 · 流量统计"
      exit 0
      ;;
    -update-check)
      if [ "$(id -u)" -ne 0 ]; then
        LOG_FILE="/tmp/vps_init.log"
      fi
      touch "$LOG_FILE" 2>/dev/null || true
      check_for_update
      exit $?
      ;;
    -update-tools)
      require_root
      touch "$LOG_FILE"
      sync_companion_scripts
      exit $?
      ;;
    -sectools-check)
      touch "$LOG_FILE" 2>/dev/null || true
      ensure_utf8_output
      check_sectools_status
      check_mcp_apt_tools || true
      exit 0
      ;;
    -sectools-help)
      print_sectools_catalog
      exit 0
      ;;
    "")
      print_usage
      exit 0
      ;;
  esac

  require_root
  touch "$LOG_FILE"
  log "===== ${SCRIPT_NAME} v${SCRIPT_VERSION} ====="
  check_ubuntu

  # 单独处理地区配置（不跑后续安装）
  case "$cmd" in
    -region)
      configure_region_cmd "${2:-}"
      ;;
  esac

  if needs_region "$cmd"; then
    if [ "$cmd" = "-all" ]; then
      init_region "interactive"
    else
      init_region
    fi
  fi

  # 凡会动 apt 的子命令：暂停后台更新，EXIT 时自动恢复
  if needs_apt_guard "$cmd"; then
    pause_background_apt
    trap 'resume_background_apt' EXIT
  fi

  case "$cmd" in
    -all)
      maybe_setup_apt_mirror_cn || true
      setup_time_sync
      install_zsh
      setup_swap
      install_docker
      setup_pip
      install_java8
      install_golang
      install_scanners
      beautify_terminal
      setup_noproxy_zshrc
      setup_traffic_monitor
      ok "基础环境安装完毕"
      ok "DNS 修改: -dns  |  安全工具: -sectools  |  代理: -clash  |  关代理: noproxy  |  流量: traffic-check  |  卸载监控: -remove"
      ;;
    -zsh)       install_zsh ;;
    -swap)      setup_swap ;;
    -docker)    install_docker ;;
    -pip)       setup_pip ;;
    -remove)    remove_cloud_agent ;;
    -aliyun)    remove_aliyun ;;
    -java)      install_java8 ;;
    -go)        install_golang ;;
    -scan)      install_scanners ;;
    -beauty)    beautify_terminal ;;
    -time)      setup_time_sync ;;
    -traffic)   setup_traffic_monitor ;;
    -noproxy)   disable_all_proxy ;;
    -dns)       setup_dns ;;
    -clash)     install_clash "${2:-}" ;;
    -cnvd-vpn)  install_cnvd_vpn "${2:-}" "${3:-}" ;;
    -bugbox-vpn) install_bugbox_vpn "${2:-}" "${3:-}" ;;
    -task-vpn)  install_task_vpn "${2:-}" ;;
    -clash-harden)
      harden_mihomo_config "/etc/mihomo/config.yaml"
      systemctl restart mihomo 2>/dev/null || true
      ok "已重启 mihomo"
      ;;
    -oneforall) install_oneforall ;;
    -enscan)    install_enscan ;;
    -subfinder) install_subfinder ;;
    -amass)     install_amass ;;
    -nuclei)    install_nuclei ;;
    -httpx)     install_httpx ;;
    -naabu)     install_naabu ;;
    -dnsx)      install_dnsx ;;
    -shuffledns) install_shuffledns ;;
    -ehole)     install_ehole ;;
    -urlfinder) install_urlfinder ;;
    -gowitness) install_gowitness ;;
    -favup)     install_favup ;;
    -fscan)     install_fscan ;;
    -uncover)   install_uncover ;;
    -mcp-apt)   install_mcp_apt_tools ;;
    -mcp-apt-check) check_mcp_apt_tools ;;
    -ssh)       setup_ssh_login "${2:-}" ;;
    -pve)       setup_pve_guest "${2:-}" ;;
    -sectools)  install_sectools ;;
    -update)    perform_update ;;
    *) err "未知选项: $cmd"; print_usage; exit 1 ;;
  esac

  ok "完成。日志见: ${LOG_FILE}"
}

main "$@"
