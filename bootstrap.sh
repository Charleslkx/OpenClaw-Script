#!/usr/bin/env bash
set -euo pipefail

BOLD='\033[1m'
INFO='\033[38;2;255;138;91m'
WARN='\033[38;2;255;176;32m'
ERROR='\033[38;2;226;61;45m'
SUCCESS='\033[38;2;47;191;113m'
NC='\033[0m'

log_info() { echo -e "${INFO}$*${NC}"; }
log_warn() { echo -e "${WARN}$*${NC}"; }
log_error() { echo -e "${ERROR}$*${NC}"; }
log_ok() { echo -e "${SUCCESS}$*${NC}"; }

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "缺少命令: $cmd"
    exit 1
  fi
}

as_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-Y}"
  local reply
  while true; do
    if [[ "$default" == "Y" ]]; then
      read -r -p "$prompt [Y/n]: " reply
      reply="${reply:-Y}"
    else
      read -r -p "$prompt [y/N]: " reply
      reply="${reply:-N}"
    fi
    case "$reply" in
      Y|y) return 0 ;;
      N|n) return 1 ;;
      *) echo "请输入 y 或 n" ;;
    esac
  done
}

prompt_number() {
  local prompt="$1"
  local default="$2"
  local min="${3:-0}"
  local value
  while true; do
    read -r -p "$prompt [$default]: " value
    value="${value:-$default}"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= min )); then
      echo "$value"
      return 0
    fi
    echo "请输入 >= $min 的数字。"
  done
}

prompt_text() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "$prompt [$default]: " value
  echo "${value:-$default}"
}

is_linux() {
  [[ "$(uname -s 2>/dev/null || true)" == "Linux" ]]
}

get_mem_mb() {
  local mem_kb
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [[ -z "$mem_kb" || "$mem_kb" == "0" ]]; then
    echo 0
    return
  fi
  echo $((mem_kb / 1024))
}

calc_defaults() {
  local mem_mb="$1"

  # Fixed ratio (industry-typical for servers) with min/max caps.
  # zram = 50% RAM, min 512MB, max 8192MB
  # swap = 50% RAM, min 1024MB, max 16384MB
  DEFAULT_ZRAM_MB=$(( mem_mb / 2 ))
  if (( DEFAULT_ZRAM_MB < 512 )); then
    DEFAULT_ZRAM_MB=512
  fi
  if (( DEFAULT_ZRAM_MB > 8192 )); then
    DEFAULT_ZRAM_MB=8192
  fi

  DEFAULT_SWAP_MB=$(( mem_mb / 2 ))
  if (( DEFAULT_SWAP_MB < 1024 )); then
    DEFAULT_SWAP_MB=1024
  fi
  if (( DEFAULT_SWAP_MB > 16384 )); then
    DEFAULT_SWAP_MB=16384
  fi

  DEFAULT_SWAPPINESS=180
  DEFAULT_ZRAM_PRIORITY=100
  DEFAULT_SWAP_PRIORITY=10
}

pick_compression() {
  local available
  available=""
  if [[ -r /sys/module/zram/parameters/comp_algorithm ]]; then
    available="$(cat /sys/module/zram/parameters/comp_algorithm)"
  fi
  if [[ -z "$available" ]]; then
    echo "zstd"
    return
  fi
  if echo "$available" | grep -q "zstd"; then
    echo "zstd"
    return
  fi
  if echo "$available" | grep -q "lz4"; then
    echo "lz4"
    return
  fi
  if echo "$available" | grep -q "lzo-rle"; then
    echo "lzo-rle"
    return
  fi
  if echo "$available" | grep -q "lzo"; then
    echo "lzo"
    return
  fi
  echo "$(echo "$available" | awk '{print $1}' | tr -d '[]')"
}

apply_swappiness() {
  local value="$1"
  local conf="/etc/sysctl.d/99-openclaw-swappiness.conf"
  as_root /bin/sh -c "printf 'vm.swappiness=%s\n' '$value' > '$conf'"
  as_root sysctl -q -p "$conf" >/dev/null
}

ensure_swapfile() {
  local swap_mb="$1"
  local swap_pri="$2"
  local swapfile="/swapfile"

  if (( swap_mb <= 0 )); then
    log_warn "swap 大小为 0，跳过 swapfile 配置。"
    return 0
  fi

  if [[ -f "$swapfile" ]]; then
    log_warn "检测到已有 $swapfile，将复用现有 swapfile。"
  else
    log_info "创建 swapfile: ${swap_mb} MB"
    if command -v fallocate >/dev/null 2>&1; then
      as_root /bin/sh -c "fallocate -l ${swap_mb}M '$swapfile'"
    else
      as_root /bin/sh -c "dd if=/dev/zero of='$swapfile' bs=1M count=${swap_mb} status=progress"
    fi
    as_root chmod 600 "$swapfile"
    as_root mkswap "$swapfile" >/dev/null
  fi

  if swapon --show=NAME --noheadings 2>/dev/null | grep -q "^$swapfile$"; then
    as_root swapoff "$swapfile" || true
  fi
  as_root swapon -p "$swap_pri" "$swapfile"

  if grep -q "^$swapfile" /etc/fstab; then
    as_root /bin/sh -c "sed -i 's#^$swapfile .*#${swapfile} none swap sw,pri=${swap_pri} 0 0#' /etc/fstab"
  else
    as_root /bin/sh -c "printf '%s\n' '${swapfile} none swap sw,pri=${swap_pri} 0 0' >> /etc/fstab"
  fi
}

ensure_zram() {
  local zram_mb="$1"
  local zram_pri="$2"
  local comp="$3"
  local zram_bytes=$(( zram_mb * 1024 * 1024 ))

  if (( zram_mb <= 0 )); then
    log_warn "zram 大小为 0，跳过 zram 配置。"
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    local unit="/etc/systemd/system/openclaw-zram.service"
    local modprobe
    local mkswap
    local swapon_bin
    local swapoff_bin
    modprobe="$(command -v modprobe || echo /sbin/modprobe)"
    mkswap="$(command -v mkswap || echo /sbin/mkswap)"
    swapon_bin="$(command -v swapon || echo /sbin/swapon)"
    swapoff_bin="$(command -v swapoff || echo /sbin/swapoff)"

    as_root /bin/sh -c "cat > '$unit' <<'UNIT'
[Unit]
Description=OpenClaw ZRAM Swap
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${modprobe} zram num_devices=1
ExecStart=/bin/sh -c 'if [ -w /sys/block/zram0/comp_algorithm ]; then echo ${comp} > /sys/block/zram0/comp_algorithm; fi'
ExecStart=/bin/sh -c 'echo ${zram_bytes} > /sys/block/zram0/disksize'
ExecStart=${mkswap} /dev/zram0
ExecStart=${swapon_bin} -p ${zram_pri} /dev/zram0
ExecStop=${swapoff_bin} /dev/zram0
ExecStop=/bin/sh -c 'if [ -w /sys/block/zram0/reset ]; then echo 1 > /sys/block/zram0/reset; fi'

[Install]
WantedBy=multi-user.target
UNIT"

    as_root systemctl daemon-reload
    as_root systemctl enable --now openclaw-zram.service
  else
    local script="/usr/local/sbin/openclaw-zram.sh"
    local rc_local=""
    if [[ -f /etc/rc.local ]]; then
      rc_local="/etc/rc.local"
    elif [[ -f /etc/rc.d/rc.local ]]; then
      rc_local="/etc/rc.d/rc.local"
    fi

    log_warn "未检测到 systemd，使用 rc.local/cron 进行持久化配置。"
    as_root /bin/sh -c "cat > '$script' <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
MODPROBE=\"\$(command -v modprobe || echo /sbin/modprobe)\"
MKSWAP=\"\$(command -v mkswap || echo /sbin/mkswap)\"
SWAPON=\"\$(command -v swapon || echo /sbin/swapon)\"
SWAPOFF=\"\$(command -v swapoff || echo /sbin/swapoff)\"

\"\$MODPROBE\" zram num_devices=1
if [ -w /sys/block/zram0/comp_algorithm ]; then
  echo ${comp} > /sys/block/zram0/comp_algorithm
fi
if \$SWAPON --show=NAME --noheadings 2>/dev/null | grep -q '^/dev/zram0$'; then
  \$SWAPOFF /dev/zram0 || true
fi
if [ -w /sys/block/zram0/reset ]; then
  echo 1 > /sys/block/zram0/reset
fi
echo ${zram_bytes} > /sys/block/zram0/disksize
\$MKSWAP /dev/zram0
\$SWAPON -p ${zram_pri} /dev/zram0
SCRIPT"
    as_root chmod 755 "$script"

    local persisted=false
    if [[ -n "$rc_local" ]]; then
      as_root chmod +x "$rc_local"
      if ! grep -q "$script" "$rc_local"; then
        as_root /bin/sh -c "printf '\n%s\n' '$script' >> '$rc_local'"
      fi
      persisted=true
    fi

    if command -v crontab >/dev/null 2>&1; then
      as_root /bin/sh -c "cat > /etc/cron.d/openclaw-zram <<'CRON'
@reboot root ${script}
CRON"
      persisted=true
    fi

    if [[ "$persisted" != true ]]; then
      log_warn "未找到 rc.local 或 cron，无法保证 zram 持久化，请手动配置开机执行 $script。"
    fi

    as_root /bin/sh -c "$script"
  fi
}

configure_memory() {
  if ! is_linux; then
    log_warn "非 Linux 系统，跳过 zram/swap 配置。"
    return 0
  fi

  require_cmd swapon
  require_cmd mkswap
  require_cmd sysctl

  local mem_mb
  mem_mb="$(get_mem_mb)"
  if (( mem_mb <= 0 )); then
    log_warn "无法读取内存信息，跳过 zram/swap 配置。"
    return 0
  fi

  calc_defaults "$mem_mb"
  local default_comp
  default_comp="$(pick_compression)"

  echo -e "${BOLD}系统检测${NC}"
  echo "- OS: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -a)"
  echo "- 物理内存: ${mem_mb} MB"
  echo "- 当前 swap:"
  swapon --show || true
  echo

  echo -e "${BOLD}建议配置${NC}"
  echo "- zram 大小: ${DEFAULT_ZRAM_MB} MB"
  echo "- zram 优先级: ${DEFAULT_ZRAM_PRIORITY}"
  echo "- zram 压缩算法: ${default_comp}"
  echo "- swapfile 大小: ${DEFAULT_SWAP_MB} MB"
  echo "- swapfile 优先级: ${DEFAULT_SWAP_PRIORITY}"
  echo "- vm.swappiness: ${DEFAULT_SWAPPINESS}"
  echo

  local zram_mb="$DEFAULT_ZRAM_MB"
  local swap_mb="$DEFAULT_SWAP_MB"
  local swappiness="$DEFAULT_SWAPPINESS"
  local zram_pri="$DEFAULT_ZRAM_PRIORITY"
  local swap_pri="$DEFAULT_SWAP_PRIORITY"
  local comp="$default_comp"

  if ! ask_yes_no "是否接受以上默认配置?" "Y"; then
    echo
    zram_mb="$(prompt_number '请输入 zram 大小 (MB, 0 表示关闭)' "$DEFAULT_ZRAM_MB" 0)"
    zram_pri="$(prompt_number '请输入 zram 优先级' "$DEFAULT_ZRAM_PRIORITY" 0)"
    comp="$(prompt_text '请输入 zram 压缩算法 (例如 zstd/lz4/lzo-rle)' "$default_comp")"
    swap_mb="$(prompt_number '请输入 swapfile 大小 (MB, 0 表示关闭)' "$DEFAULT_SWAP_MB" 0)"
    swap_pri="$(prompt_number '请输入 swapfile 优先级' "$DEFAULT_SWAP_PRIORITY" 0)"
    swappiness="$(prompt_number '请输入 vm.swappiness (0-200)' "$DEFAULT_SWAPPINESS" 0)"
  fi

  echo
  if [[ -r /sys/module/zram/parameters/comp_algorithm ]]; then
    local available
    available="$(cat /sys/module/zram/parameters/comp_algorithm)"
    if ! echo "$available" | grep -qw "$comp"; then
      log_warn "压缩算法 ${comp} 不在可用列表中，将回退到 ${default_comp}。"
      comp="$default_comp"
    fi
  fi

  log_info "将应用以下配置:"
  echo "- zram 大小: ${zram_mb} MB"
  echo "- zram 优先级: ${zram_pri}"
  echo "- zram 压缩算法: ${comp}"
  echo "- swapfile 大小: ${swap_mb} MB"
  echo "- swapfile 优先级: ${swap_pri}"
  echo "- vm.swappiness: ${swappiness}"
  echo

  if ! ask_yes_no "是否继续应用配置?" "Y"; then
    log_warn "已跳过 zram/swap 配置。"
    return 0
  fi

  log_info "需要 sudo 权限来配置 zram/swap。"
  apply_swappiness "$swappiness"
  ensure_swapfile "$swap_mb" "$swap_pri"
  ensure_zram "$zram_mb" "$zram_pri" "$comp"

  log_ok "zram/swap 配置完成。"
  echo
  log_info "当前 swap 状态:"
  swapon --show || true
}

install_openclaw() {
  log_info "开始安装 OpenClaw (跳过 onboarding)..."
  require_cmd curl
  curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard

  if ! command -v openclaw >/dev/null 2>&1; then
    local npm_bin
    npm_bin="$(npm bin -g 2>/dev/null || true)"
    if [[ -n "$npm_bin" ]]; then
      export PATH="$npm_bin:$PATH"
    fi
  fi

  if ! command -v openclaw >/dev/null 2>&1; then
    log_error "未找到 openclaw 命令，请重新打开终端或手动加入 PATH 后再继续。"
    exit 1
  fi

  log_ok "OpenClaw 安装完成。"
}

install_plugins() {
  log_info "安装飞书插件..."
  openclaw plugins install @m1heng-clawd/feishu
  log_ok "飞书插件安装完成。"
}

setup_coding_plan() {
  if ask_yes_no "是否使用字节 Coding Plan?" "N"; then
    local ark_key
    local model_id
    local feishu_app_id
    local feishu_app_secret

    while true; do
      read -r -s -p "请输入方舟 API Key: " ark_key
      echo
      if [[ -n "$ark_key" ]]; then
        break
      fi
      echo "API Key 不能为空。"
    done
    read -r -p "请输入 model_id (默认 glm-4.7): " model_id
    model_id="${model_id:-glm-4.7}"
    read -r -p "请输入飞书 App ID: " feishu_app_id
    while true; do
      read -r -s -p "请输入飞书 App Secret: " feishu_app_secret
      echo
      if [[ -n "$feishu_app_secret" ]]; then
        break
      fi
      echo "App Secret 不能为空。"
    done
    echo

    log_info "开始安装 Coding Plan 配置..."
    curl -fsSL https://openclaw.tos-cn-beijing.volces.com/setup.sh | bash -s -- \
      --ark-coding-plan "true" \
      --ark-api-key "$ark_key" \
      --ark-model-id "$model_id" \
      --feishu-app-id "$feishu_app_id" \
      --feishu-app-secret "$feishu_app_secret"
    log_ok "Coding Plan 配置完成。"
  else
    log_warn "已跳过 Coding Plan 配置。"
  fi
}

run_openclaw_config() {
  log_info "进入 openclaw config 完成后续配置..."
  openclaw config
}

main() {
  configure_memory
  install_openclaw
  install_plugins
  setup_coding_plan
  run_openclaw_config
}

main "$@"
