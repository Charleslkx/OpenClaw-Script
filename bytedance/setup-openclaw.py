#!/usr/bin/env python3

import json
import os
import secrets
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
import urllib.request

LOG_FILE = "/var/log/openclaw-setup.log"
CONFIG_DIR = Path("/root/.openclaw")
CONFIG_FILE = CONFIG_DIR / "openclaw.json"
ENV_FILE = CONFIG_DIR / ".env"
SCRIPT_VERSION = "0203.1"


def log(msg: str):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{timestamp}] [openclaw] {msg}"
    print(line)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except PermissionError:
        pass


def mask(value: str) -> str:
    return "***SET***" if value else "(not set)"


def detect_site() -> str:
    try:
        req = urllib.request.Request("http://100.96.0.96/volcstack/latest/site_name")
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.read().decode().strip()
    except Exception:
        return "unknown"


def get_instance_id() -> str:
    try:
        req = urllib.request.Request("http://100.96.0.96/latest/instance_id")
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.read().decode().strip()
    except Exception:
        return "unknown"


def load_env_file() -> dict:
    env_vars = {}
    if not ENV_FILE.exists():
        return env_vars
    with open(ENV_FILE) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, value = line.split("=", 1)
                env_vars[key.strip()] = value.strip()
    return env_vars


def get_config(env_file_vars: dict, key: str) -> str:
    return os.environ.get(key) or env_file_vars.get(key) or ""


def get_ark_url(site: str, coding_plan: bool) -> str:
    if site == "BytePlus":
        return (
            "https://ark.ap-southeast.bytepluses.com/api/coding/v3"
            if coding_plan
            else "https://ark.ap-southeast.bytepluses.com/api/v3"
        )
    return (
        "https://ark.cn-beijing.volces.com/api/coding/v3"
        if coding_plan
        else "https://ark.cn-beijing.volces.com/api/v3"
    )


def deep_merge(base: dict, update: dict) -> dict:
    result = base.copy()
    for key, value in update.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def main():
    log("========== setup-openclaw.py started ==========")

    log(f"Loading config from {ENV_FILE}...")
    env_file_vars = load_env_file()
    if env_file_vars:
        log(f"Found .env file, loaded {len(env_file_vars)} vars")
    else:
        log("No .env file found, using environment variables only")

    ark_api_key = get_config(env_file_vars, "ARK_API_KEY")
    ark_model_id = get_config(env_file_vars, "ARK_MODEL_ID")
    ark_coding_plan = get_config(env_file_vars, "ARK_CODING_PLAN") == "true"
    feishu_app_id = get_config(env_file_vars, "FEISHU_APP_ID")
    feishu_app_secret = get_config(env_file_vars, "FEISHU_APP_SECRET")
    telegram_bot_token = get_config(env_file_vars, "TELEGRAM_BOT_TOKEN")
    dingtalk_client_id = get_config(env_file_vars, "DINGTALK_CLIENT_ID")
    dingtalk_client_secret = get_config(env_file_vars, "DINGTALK_CLIENT_SECRET")
    wecom_token = get_config(env_file_vars, "WECOM_TOKEN")
    wecom_encoding_aes_key = get_config(env_file_vars, "WECOM_ENCODING_AES_KEY")

    log("Final config:")
    log(f"  ARK_API_KEY: {mask(ark_api_key)}")
    log(f"  ARK_MODEL_ID: {ark_model_id or '(not set)'}")
    log(f"  ARK_CODING_PLAN: {ark_coding_plan}")
    log(f"  FEISHU_APP_ID: {mask(feishu_app_id)}")
    log(f"  FEISHU_APP_SECRET: {mask(feishu_app_secret)}")
    log(f"  TELEGRAM_BOT_TOKEN: {mask(telegram_bot_token)}")
    log(f"  DINGTALK_CLIENT_ID: {mask(dingtalk_client_id)}")
    log(f"  DINGTALK_CLIENT_SECRET: {mask(dingtalk_client_secret)}")
    log(f"  WECOM_TOKEN: {mask(wecom_token)}")
    log(f"  WECOM_ENCODING_AES_KEY: {mask(wecom_encoding_aes_key)}")

    if CONFIG_FILE.exists():
        log(f"Loading existing config from {CONFIG_FILE}...")
        with open(CONFIG_FILE) as f:
            config = json.load(f)
    else:
        log("No existing config, starting fresh...")
        config = {}

    site = detect_site()
    log(f"Site: {site}")
    
    instance_id = get_instance_id()
    log(f"Instance ID: {instance_id}")

    if "gateway" not in config:
        config["gateway"] = {}
    if "auth" not in config["gateway"]:
        config["gateway"]["auth"] = {}
    gateway_token = secrets.token_hex(24)
    config["gateway"]["auth"]["token"] = gateway_token
    log(f"Generated gateway auth token: {gateway_token[:8]}...")

    if ark_api_key and ark_model_id:
        log("Configuring ARK model...")
        ark_url = get_ark_url(site, ark_coding_plan)
        log(f"ARK_BASE_URL: {ark_url}")

        ark_config = {
            "mode": "merge",
            "providers": {
                "ark": {
                    "baseUrl": ark_url,
                    "apiKey": ark_api_key,
                    "api": "openai-completions",
                    "models": [
                        {
                            "id": ark_model_id,
                            "name": ark_model_id,
                            "reasoning": False,
                            "input": ["text"],
                            "cost": {
                                "input": 0,
                                "output": 0,
                                "cacheRead": 0,
                                "cacheWrite": 0,
                            },
                            "contextWindow": 200000,
                            "maxTokens": 8192,
                            "headers": {
                                "X-Client-Request-Id": f"ecs-openclaw/{SCRIPT_VERSION}/{instance_id}"
                            },
                            "compat": {"supportsDeveloperRole": False},
                        }
                    ],
                }
            },
        }
        config["models"] = deep_merge(config.get("models", {}), ark_config)

        if "agents" not in config:
            config["agents"] = {}
        if "defaults" not in config["agents"]:
            config["agents"]["defaults"] = {}
        config["agents"]["defaults"]["model"] = {"primary": f"ark/{ark_model_id}"}
        config["agents"]["defaults"]["models"] = {f"ark/{ark_model_id}": {}}
        log("ARK configured successfully")
    else:
        log("Skipping ARK config (ARK_API_KEY or ARK_MODEL_ID not set)")

    if "channels" not in config:
        config["channels"] = {}

    if feishu_app_id:
        log("Configuring Feishu App ID...")
        if "feishu" not in config["channels"]:
            config["channels"]["feishu"] = {}
        config["channels"]["feishu"]["appId"] = feishu_app_id
        log("Feishu App ID configured")
    else:
        log("Skipping Feishu App ID (not set)")

    if feishu_app_secret:
        log("Configuring Feishu App Secret...")
        if "feishu" not in config["channels"]:
            config["channels"]["feishu"] = {}
        config["channels"]["feishu"]["appSecret"] = feishu_app_secret
        log("Feishu App Secret configured")
    else:
        log("Skipping Feishu App Secret (not set)")

    if telegram_bot_token:
        log("Configuring Telegram...")
        config["channels"]["telegram"] = {
            "enabled": True,
            "dmPolicy": "pairing",
            "botToken": telegram_bot_token,
            "groupPolicy": "allowlist",
            "streamMode": "partial",
        }
        if "plugins" not in config:
            config["plugins"] = {}
        if "entries" not in config["plugins"]:
            config["plugins"]["entries"] = {}
        config["plugins"]["entries"]["telegram"] = {"enabled": True}
        log("Telegram configured")
    else:
        log("Skipping Telegram (not set)")

    if dingtalk_client_id and dingtalk_client_secret:
        log("Configuring DingTalk...")
        gateway_token = config["gateway"]["auth"]["token"]
        config["channels"]["dingtalk-connector"] = {
            "enabled": True,
            "clientId": dingtalk_client_id,
            "clientSecret": dingtalk_client_secret,
            "gatewayToken": gateway_token,
            "sessionTimeout": 1800000,
        }
        if "gateway" not in config:
            config["gateway"] = {}
        if "http" not in config["gateway"]:
            config["gateway"]["http"] = {}
        if "endpoints" not in config["gateway"]["http"]:
            config["gateway"]["http"]["endpoints"] = {}
        if "chatCompletions" not in config["gateway"]["http"]["endpoints"]:
            config["gateway"]["http"]["endpoints"]["chatCompletions"] = {}
        config["gateway"]["http"]["endpoints"]["chatCompletions"]["enabled"] = True
        log("DingTalk configured (chatCompletions endpoint enabled)")
    else:
        log("Skipping DingTalk (DINGTALK_CLIENT_ID or DINGTALK_CLIENT_SECRET not set)")

    if wecom_token and wecom_encoding_aes_key:
        log("Configuring WeCom...")
        if len(wecom_encoding_aes_key) != 43:
            log(f"Warning: EncodingAESKey should be 43 characters (got {len(wecom_encoding_aes_key)})")
        config["channels"]["wecom"] = {
            "enabled": True,
            "webhookPath": "/wecom",
            "token": wecom_token,
            "encodingAESKey": wecom_encoding_aes_key,
        }
        log("Enabling public access for WeCom...")
        if "gateway" not in config:
            config["gateway"] = {}
        config["gateway"]["bind"] = "lan"
        if "controlUi" not in config["gateway"]:
            config["gateway"]["controlUi"] = {}
        config["gateway"]["controlUi"]["enabled"] = True
        config["gateway"]["controlUi"]["allowInsecureAuth"] = True
        if "http" not in config["gateway"]:
            config["gateway"]["http"] = {}
        if "endpoints" not in config["gateway"]["http"]:
            config["gateway"]["http"]["endpoints"] = {}
        if "chatCompletions" not in config["gateway"]["http"]["endpoints"]:
            config["gateway"]["http"]["endpoints"]["chatCompletions"] = {}
        config["gateway"]["http"]["endpoints"]["chatCompletions"]["enabled"] = True
        log("WeCom configured (public access enabled)")
    else:
        log("Skipping WeCom (WECOM_TOKEN or WECOM_ENCODING_AES_KEY not set)")

    now = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.000Z")
    if "meta" not in config:
        config["meta"] = {}
    config["meta"]["lastTouchedAt"] = now

    if CONFIG_FILE.exists():
        backup = CONFIG_FILE.with_suffix(".json.bak")
        shutil.copy(CONFIG_FILE, backup)
        log(f"Backup created: {backup}")

    log(f"Writing config to {CONFIG_FILE}...")
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    log("Config saved")

    uid = os.getuid()
    xdg_runtime_dir = f"/run/user/{uid}"
    bus_socket = Path(xdg_runtime_dir) / "bus"

    log(f"Enabling linger for user {uid}...")
    try:
        subprocess.run(["loginctl", "enable-linger", str(uid)], check=True)
        log("Linger enabled!")
    except subprocess.CalledProcessError as e:
        log(f"Warning: Failed to enable linger: {e}")

    log(f"Waiting for user bus socket ({bus_socket})...")
    max_wait = 60
    waited = 0
    while not bus_socket.exists() and waited < max_wait:
        time.sleep(1)
        waited += 1
        if waited % 10 == 0:
            log(f"Still waiting for bus socket... ({waited}s)")

    if bus_socket.exists():
        log("Bus socket ready!")
    else:
        log(f"Warning: Bus socket not found after {max_wait}s, continuing anyway...")

    os.environ["XDG_RUNTIME_DIR"] = xdg_runtime_dir
    log(f"XDG_RUNTIME_DIR: {xdg_runtime_dir}")

    # Configure memory limits
    service_file = Path("/root/.config/systemd/user/openclaw-gateway.service")
    if service_file.exists():
        log("Configuring memory limits...")
        try:
            # Get total system memory (MB)
            result = subprocess.run(
                ["free", "-m"], capture_output=True, text=True, check=True
            )
            for line in result.stdout.splitlines():
                if line.startswith("Mem:"):
                    total_mem_mb = int(line.split()[1])
                    break
            else:
                total_mem_mb = 0

            if total_mem_mb > 0:
                memory_max = f"{total_mem_mb * 80 // 100}M"
                memory_high = f"{total_mem_mb * 75 // 100}M"
                log(
                    f"Total memory: {total_mem_mb}MB, MemoryMax: {memory_max}, MemoryHigh: {memory_high}"
                )

                # Read service file
                content = service_file.read_text()

                # Remove existing memory limit configs
                lines = []
                for line in content.splitlines():
                    if not line.strip().startswith(("MemoryMax=", "MemoryHigh=")):
                        lines.append(line)
                content = "\n".join(lines)

                # Insert memory limits after [Service]
                if "[Service]" in content:
                    content = content.replace(
                        "[Service]",
                        f"[Service]\nMemoryMax={memory_max}\nMemoryHigh={memory_high}",
                    )
                    service_file.write_text(content)
                    log("Memory limits configured in service file")
                else:
                    log("Warning: [Service] section not found in service file")
            else:
                log("Warning: Could not determine total memory")
        except Exception as e:
            log(f"Warning: Failed to configure memory limits: {e}")
    else:
        log(f"Warning: Service file not found: {service_file}")

    # Reload systemd daemon
    log("Reloading systemd user daemon...")
    try:
        subprocess.run(["systemctl", "--user", "daemon-reload"], check=True)
        log("Daemon reloaded!")
    except subprocess.CalledProcessError as e:
        log(f"Warning: daemon-reload failed: {e}")

    max_retries = 10
    retry_delay = 5
    service_name = "openclaw-gateway.service"

    log("Enabling gateway service...")
    for attempt in range(1, max_retries + 1):
        try:
            subprocess.run(["systemctl", "--user", "enable", service_name], check=True)
            log("Gateway service enabled!")
            break
        except subprocess.CalledProcessError as e:
            log(f"Enable attempt {attempt}/{max_retries} failed: {e}")
            if attempt < max_retries:
                log(f"Retrying in {retry_delay} seconds...")
                time.sleep(retry_delay)
            else:
                log("Warning: All enable attempts failed")

    log("Starting gateway service...")
    for attempt in range(1, max_retries + 1):
        try:
            subprocess.run(["systemctl", "--user", "restart", service_name], check=True)
            log("Gateway service started!")
            break
        except subprocess.CalledProcessError as e:
            log(f"Start attempt {attempt}/{max_retries} failed: {e}")
            if attempt < max_retries:
                log(f"Retrying in {retry_delay} seconds...")
                time.sleep(retry_delay)
            else:
                log("Warning: All start attempts failed")

    log("========== setup-openclaw.py completed ==========")


if __name__ == "__main__":
    main()
