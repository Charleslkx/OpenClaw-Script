#!/bin/bash

set -e

LOG_FILE="/var/log/openclaw-setup.log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [clawdbot] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

log "========== setup-clawdbot.sh started =========="

ENV_FILE="/root/.clawdbot/.env"

log "Loading config from $ENV_FILE..."
if [[ -f "$ENV_FILE" ]]; then
    log "Found .env file, loading..."
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        if [[ -z "${!key}" ]]; then
            export "$key=$value"
            log "Loaded from .env: $key"
        else
            log "Using env var (priority): $key"
        fi
    done < "$ENV_FILE"
else
    log "No .env file found, using environment variables only"
fi

log "Final config:"
log "  ARK_API_KEY: ${ARK_API_KEY:+***SET***}"
log "  ARK_MODEL_ID: $ARK_MODEL_ID"
log "  ARK_CODING_PLAN: $ARK_CODING_PLAN"
log "  FEISHU_APP_ID: ${FEISHU_APP_ID:+***SET***}"
log "  FEISHU_APP_SECRET: ${FEISHU_APP_SECRET:+***SET***}"
log "  TELEGRAM_BOT_TOKEN: ${TELEGRAM_BOT_TOKEN:+***SET***}"

if [[ -n "$ARK_API_KEY" && -n "$ARK_MODEL_ID" ]]; then
    log "Configuring ARK model..."

    log "Detecting site..."
    SITE=$(curl --connect-timeout 5 --max-time 10 -s "http://100.96.0.96/volcstack/latest/site_name" || echo "unknown")
    log "Site: $SITE"

    if [[ "$SITE" == "BytePlus" ]]; then
        if [[ "$ARK_CODING_PLAN" == "true" ]]; then
            ARK_BASE_URL="https://ark.ap-southeast.bytepluses.com/api/coding/v3"
        else
            ARK_BASE_URL="https://ark.ap-southeast.bytepluses.com/api/v3"
        fi
    else
        if [[ "$ARK_CODING_PLAN" == "true" ]]; then
            ARK_BASE_URL="https://ark.cn-beijing.volces.com/api/coding/v3"
        else
            ARK_BASE_URL="https://ark.cn-beijing.volces.com/api/v3"
        fi
    fi
    log "ARK_BASE_URL: $ARK_BASE_URL"

    ARK_CONFIG=$(cat <<EOF
{
    "mode": "merge",
    "providers": {
        "ark": {
            "baseUrl": "$ARK_BASE_URL",
            "apiKey": "$ARK_API_KEY",
            "api": "openai-completions",
            "models": [
                {
                    "id": "$ARK_MODEL_ID",
                    "name": "$ARK_MODEL_ID",
                    "reasoning": false,
                    "input": ["text"],
                    "cost": {
                        "input": 0,
                        "output": 0,
                        "cacheRead": 0,
                        "cacheWrite": 0
                    },
                    "contextWindow": 200000,
                    "maxTokens": 8192,
                    "compat": { "supportsDeveloperRole": false }
                }
            ]
        }
    }
}
EOF
)

    log "Running: clawdbot config set models ..."
    clawdbot config set models "$ARK_CONFIG"
    log "ARK configured successfully"
else
    log "Skipping ARK config (ARK_API_KEY or ARK_MODEL_ID not set)"
fi

if [[ -n "$FEISHU_APP_ID" ]]; then
    log "Configuring Feishu App ID..."
    clawdbot config set channels.feishu.appId "$FEISHU_APP_ID"
    log "Feishu App ID configured"
else
    log "Skipping Feishu App ID (not set)"
fi

if [[ -n "$FEISHU_APP_SECRET" ]]; then
    log "Configuring Feishu App Secret..."
    clawdbot config set channels.feishu.appSecret "$FEISHU_APP_SECRET"
    log "Feishu App Secret configured"
else
    log "Skipping Feishu App Secret (not set)"
fi

if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
    log "Configuring Telegram..."
    TELEGRAM_CONFIG=$(cat <<EOF
{
    "enabled": true,
    "dmPolicy": "pairing",
    "botToken": "$TELEGRAM_BOT_TOKEN",
    "groupPolicy": "allowlist",
    "streamMode": "partial"
}
EOF
)
    clawdbot config set channels.telegram "$TELEGRAM_CONFIG"
    clawdbot config set plugins.entries.telegram.enabled true
    log "Telegram configured"
else
    log "Skipping Telegram (not set)"
fi

if [[ -n "$ARK_MODEL_ID" ]]; then
    log "Setting default model to ark/$ARK_MODEL_ID..."
    clawdbot models set "ark/$ARK_MODEL_ID"
    log "Default model set"
fi

log "Restarting service..."
export XDG_RUNTIME_DIR=/run/user/$(id -u)
log "XDG_RUNTIME_DIR: $XDG_RUNTIME_DIR"
systemctl --user restart clawdbot-gateway.service
log "Service restarted!"

log "========== setup-clawdbot.sh completed =========="
