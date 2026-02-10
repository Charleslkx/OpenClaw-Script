#!/bin/bash

set -e

LOG_FILE="/var/log/openclaw-setup.log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

log "========== setup.sh started =========="

log "Parsing arguments..."
while [[ $# -gt 0 ]]; do
    case $1 in
        --ark-api-key) ARK_API_KEY="$2"; shift 2 ;;
        --ark-model-id) ARK_MODEL_ID="$2"; shift 2 ;;
        --ark-coding-plan) ARK_CODING_PLAN="$2"; shift 2 ;;
        --feishu-app-id) FEISHU_APP_ID="$2"; shift 2 ;;
        --feishu-app-secret) FEISHU_APP_SECRET="$2"; shift 2 ;;
        --telegram-bot-token) TELEGRAM_BOT_TOKEN="$2"; shift 2 ;;
        --dingtalk-client-id) DINGTALK_CLIENT_ID="$2"; shift 2 ;;
        --dingtalk-client-secret) DINGTALK_CLIENT_SECRET="$2"; shift 2 ;;
        --wecom-token) WECOM_TOKEN="$2"; shift 2 ;;
        --wecom-encoding-aes-key) WECOM_ENCODING_AES_KEY="$2"; shift 2 ;;
        --tos-base) TOS_BASE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

log "ARK_API_KEY: ${ARK_API_KEY:+***SET***}"
log "ARK_MODEL_ID: $ARK_MODEL_ID"
log "ARK_CODING_PLAN: $ARK_CODING_PLAN"
log "FEISHU_APP_ID: ${FEISHU_APP_ID:+***SET***}"
log "FEISHU_APP_SECRET: ${FEISHU_APP_SECRET:+***SET***}"
log "TELEGRAM_BOT_TOKEN: ${TELEGRAM_BOT_TOKEN:+***SET***}"
log "DINGTALK_CLIENT_ID: ${DINGTALK_CLIENT_ID:+***SET***}"
log "DINGTALK_CLIENT_SECRET: ${DINGTALK_CLIENT_SECRET:+***SET***}"
log "WECOM_TOKEN: ${WECOM_TOKEN:+***SET***}"
log "WECOM_ENCODING_AES_KEY: ${WECOM_ENCODING_AES_KEY:+***SET***}"

export ARK_API_KEY ARK_MODEL_ID ARK_CODING_PLAN FEISHU_APP_ID FEISHU_APP_SECRET TELEGRAM_BOT_TOKEN DINGTALK_CLIENT_ID DINGTALK_CLIENT_SECRET WECOM_TOKEN WECOM_ENCODING_AES_KEY

log "Detecting site..."
SITE=$(curl --connect-timeout 5 --max-time 10 -s "http://100.96.0.96/volcstack/latest/site_name" || echo "unknown")
log "Site: $SITE"

TOS_BASE="${TOS_BASE:-https://openclaw.tos-cn-beijing.volces.com}"
log "TOS_BASE: $TOS_BASE"

log "Detecting CLI tool..."
if command -v openclaw &> /dev/null; then
    ENV_DIR="/root/.openclaw"
    SETUP_SCRIPT="$TOS_BASE/setup-openclaw.py"
    SCRIPT_TYPE="python"
    log "Detected: openclaw"
elif command -v clawdbot &> /dev/null; then
    ENV_DIR="/root/.clawdbot"
    SETUP_SCRIPT="$TOS_BASE/setup-clawdbot.sh"
    SCRIPT_TYPE="bash"
    log "Detected: clawdbot"
else
    log "ERROR: neither openclaw nor clawdbot found"
    exit 1
fi

log "ENV_DIR: $ENV_DIR"
log "SETUP_SCRIPT: $SETUP_SCRIPT"

log "Creating directory $ENV_DIR..."
mkdir -p "$ENV_DIR"

log "Writing .env file..."
cat > "$ENV_DIR/.env" <<EOF
ARK_API_KEY=$ARK_API_KEY
ARK_MODEL_ID=$ARK_MODEL_ID
ARK_CODING_PLAN=$ARK_CODING_PLAN

FEISHU_APP_ID=$FEISHU_APP_ID
FEISHU_APP_SECRET=$FEISHU_APP_SECRET

TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN

DINGTALK_CLIENT_ID=$DINGTALK_CLIENT_ID
DINGTALK_CLIENT_SECRET=$DINGTALK_CLIENT_SECRET

WECOM_TOKEN=$WECOM_TOKEN
WECOM_ENCODING_AES_KEY=$WECOM_ENCODING_AES_KEY
EOF
log "Saved config to $ENV_DIR/.env"

log "Fetching setup script..."
if [[ "$SCRIPT_TYPE" == "python" ]]; then
    cd /root && wget -O setup-openclaw.py "$SETUP_SCRIPT" && python3 /root/setup-openclaw.py
else
    cd /root && wget -O setup-clawdbot.sh "$SETUP_SCRIPT" && bash /root/setup-clawdbot.sh
fi

log "========== setup.sh completed =========="
