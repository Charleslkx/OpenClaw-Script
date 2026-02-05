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


OPENCLAW_RUN_AS_USER=""
OPENCLAW_USER_PREFIX=""

detect_openclaw_user() {
  if [[ -n "${OPENCLAW_RUN_AS_USER:-}" ]]; then
    return 0
  fi

  if [[ -n "${OPENCLAW_USER:-}" ]]; then
    OPENCLAW_RUN_AS_USER="$OPENCLAW_USER"
  elif [[ $EUID -ne 0 ]]; then
    OPENCLAW_RUN_AS_USER="$(id -un)"
  elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    OPENCLAW_RUN_AS_USER="$SUDO_USER"
  else
    log_info "检测到以 root 运行，必须指定非 root 用户。"
    local candidates
    candidates="$(list_non_root_users || true)"
    if [[ -n "$candidates" ]]; then
      echo "可用非 root 用户:"
      echo "$candidates" | sed 's/^/  - /'
    else
      log_warn "未检测到可用的非 root 用户。"
    fi

    if ask_yes_no "是否创建新用户?" "Y"; then
      OPENCLAW_RUN_AS_USER="$(create_non_root_user "")"
    fi

    if [[ -z "$OPENCLAW_RUN_AS_USER" ]]; then
      while true; do
        read -r -p "请输入运行 OpenClaw 的系统用户: " OPENCLAW_RUN_AS_USER
        if [[ -n "$OPENCLAW_RUN_AS_USER" && "$OPENCLAW_RUN_AS_USER" != "root" ]]; then
          break
        fi
        echo "请提供一个非 root 用户名。"
      done
    fi
  fi

  if [[ -z "$OPENCLAW_RUN_AS_USER" || "$OPENCLAW_RUN_AS_USER" == "root" ]]; then
    log_error "OpenClaw 必须使用非 root 用户运行。"
    exit 1
  fi

  if ! id "$OPENCLAW_RUN_AS_USER" >/dev/null 2>&1; then
    log_error "用户 $OPENCLAW_RUN_AS_USER 不存在。"
    exit 1
  fi

  if command -v npm >/dev/null 2>&1; then
    OPENCLAW_USER_PREFIX="$(sudo -u "$OPENCLAW_RUN_AS_USER" -H npm config get prefix 2>/dev/null || true)"
  fi
}



run_as_openclaw_user() {
  detect_openclaw_user
  local cmd=("$@")
  local prefix_path=""
  if [[ -n "${OPENCLAW_USER_PREFIX:-}" ]]; then
    prefix_path="${OPENCLAW_USER_PREFIX}/bin"
  fi

  if [[ "$(id -un)" == "$OPENCLAW_RUN_AS_USER" ]]; then
    if [[ -n "$prefix_path" ]]; then
      PATH="$prefix_path:$PATH" "${cmd[@]}"
    else
      "${cmd[@]}"
    fi
  else
    if [[ -n "$prefix_path" ]]; then
      sudo -u "$OPENCLAW_RUN_AS_USER" -H env PATH="$prefix_path:$PATH" "${cmd[@]}"
    else
      sudo -u "$OPENCLAW_RUN_AS_USER" -H "${cmd[@]}"
    fi
  fi
}

get_openclaw_user_home() {
  detect_openclaw_user
  local home_dir
  home_dir="$(getent passwd "$OPENCLAW_RUN_AS_USER" 2>/dev/null | cut -d: -f6)"
  if [[ -z "$home_dir" ]]; then
    home_dir="$(eval echo "~$OPENCLAW_RUN_AS_USER" 2>/dev/null || true)"
  fi
  echo "$home_dir"
}


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



create_non_root_user() {
  local username="$1"
  if [[ -z "$username" ]]; then
    read -r -p "请输入要创建的用户名: " username
  fi

  if [[ -z "$username" ]]; then
    log_error "用户名不能为空。"
    return 1
  fi

  if id "$username" >/dev/null 2>&1; then
    log_error "用户 $username 已存在。"
    return 1
  fi

  log_info "创建用户: $username"
  if command -v adduser >/dev/null 2>&1; then
    as_root adduser --gecos "" "$username"
  else
    as_root useradd -m -s /bin/bash "$username"
    if ask_yes_no "是否为 $username 设置密码?" "Y"; then
      as_root passwd "$username"
    else
      log_warn "未设置密码，建议使用 SSH key 登录。"
    fi
  fi

  local sudo_group=""
  if getent group sudo >/dev/null 2>&1; then
    sudo_group="sudo"
  elif getent group wheel >/dev/null 2>&1; then
    sudo_group="wheel"
  fi

  if [[ -n "$sudo_group" ]]; then
    as_root usermod -aG "$sudo_group" "$username"
    log_ok "已将 $username 加入 $sudo_group 组。"
  else
    log_warn "未找到 sudo/wheel 组，请手动配置 sudo 权限。"
  fi

  echo "$username"
}



enable_user_linger() {
  detect_openclaw_user
  if command -v loginctl >/dev/null 2>&1; then
    as_root loginctl enable-linger "$OPENCLAW_RUN_AS_USER" >/dev/null 2>&1 || true
  fi
}

list_non_root_users() {
  if ! command -v getent >/dev/null 2>&1; then
    return 1
  fi
  getent passwd | awk -F: '($3>=1000)&&($1!="nobody")&&($7!~/(\/usr\/sbin\/nologin|\/bin\/false)/){print $1}'
}

# 检查是否已有 zram 配置
has_zram_configured() {
  # 检查是否存在 zram 设备且已启用 swap
  if swapon --show=NAME --noheadings 2>/dev/null | grep -q "^/dev/zram"; then
    return 0
  fi
  # 检查是否存在 zram 服务
  if command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service --all 2>/dev/null | grep -q "zram"; then
    return 0
  fi
  return 1
}

# 检查是否已有 swap 配置（不包括 zram）
has_swap_configured() {
  # 检查是否存在非 zram 的 swap
  if swapon --show=NAME --noheadings 2>/dev/null | grep -v "^/dev/zram" | grep -q .; then
    return 0
  fi
  # 检查是否存在 swapfile
  if [[ -f /swapfile ]]; then
    return 0
  fi
  # 检查 /etc/fstab 中是否有 swap 配置
  if grep -v "^#" /etc/fstab 2>/dev/null | grep -q "swap"; then
    return 0
  fi
  return 1
}

# 输出当前内存配置信息
show_current_memory_config() {
  log_info "当前内存配置信息："
  echo
  echo "- 物理内存:"
  free -h 2>/dev/null || cat /proc/meminfo 2>/dev/null | head -5
  echo
  echo "- Swap 状态:"
  swapon --show 2>/dev/null || echo "  无 swap 配置"
  echo
  echo "- Zram 状态:"
  if [[ -d /sys/block/zram0 ]]; then
    echo "  zram0 存在"
    if [[ -r /sys/block/zram0/comp_algorithm ]]; then
      echo "  压缩算法: $(cat /sys/block/zram0/comp_algorithm 2>/dev/null | tr -d '[]')"
    fi
    if [[ -r /sys/block/zram0/disksize ]]; then
      echo "  磁盘大小: $(cat /sys/block/zram0/disksize 2>/dev/null | numfmt --to=iec 2>/dev/null || cat /sys/block/zram0/disksize 2>/dev/null)"
    fi
  else
    echo "  无 zram 配置"
  fi
  echo
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

  # 检查是否已有配置
  local has_zram=false
  local has_swap=false

  if has_zram_configured; then
    has_zram=true
  fi

  if has_swap_configured; then
    has_swap=true
  fi

  # 如果已有配置，跳过并显示信息
  if [[ "$has_zram" == true || "$has_swap" == true ]]; then
    log_info "检测到已有内存配置："
    [[ "$has_zram" == true ]] && echo "  - ZRAM: 已配置"
    [[ "$has_swap" == true ]] && echo "  - SWAP: 已配置"
    echo
    show_current_memory_config
    log_ok "跳过 zram/swap 配置（已有配置）。"
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
  run_as_openclaw_user bash -c "curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard"

  if ! run_as_openclaw_user bash -c "command -v openclaw >/dev/null 2>&1"; then
    log_error "未找到 openclaw 命令，请确认安装用户或 PATH 配置。"
    exit 1
  fi

  log_ok "OpenClaw 安装完成。"
}


ensure_gateway_service() {
  log_info "检查 Gateway service..."
  local home_dir
  local unit_path
  home_dir="$(get_openclaw_user_home)"
  unit_path="${home_dir}/.config/systemd/user/openclaw-gateway.service"

  if [[ -f "$unit_path" ]]; then
    log_ok "Gateway service 已存在: $unit_path"
    return 0
  fi

  log_warn "未找到 Gateway service，准备安装（用户: ${OPENCLAW_RUN_AS_USER}）。"
  enable_user_linger
  if ! run_as_openclaw_user openclaw gateway install; then
    log_warn "Gateway service 安装失败，请手动执行: openclaw gateway install"
    return 1
  fi

  if [[ -f "$unit_path" ]]; then
    log_ok "Gateway service 已安装: $unit_path"
  else
    log_warn "Gateway service 安装完成，但未检测到 unit 文件。"
  fi
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
    run_as_openclaw_user bash -c "curl -fsSL https://openclaw.tos-cn-beijing.volces.com/setup.sh | bash -s -- --ark-coding-plan \"true\" --ark-api-key \"$ark_key\" --ark-model-id \"$model_id\" --feishu-app-id \"$feishu_app_id\" --feishu-app-secret \"$feishu_app_secret\""
    log_ok "Coding Plan 配置完成。"
  else
    log_warn "已跳过 Coding Plan 配置。"
  fi
}

run_openclaw_config() {
  log_info "进入 openclaw config 完成后续配置..."
  run_as_openclaw_user openclaw config
}

main() {
  configure_memory
  install_openclaw
  ensure_gateway_service
  setup_coding_plan
  run_openclaw_config
}

main "$@"
