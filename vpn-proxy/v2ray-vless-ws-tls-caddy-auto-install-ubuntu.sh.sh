#!/bin/bash

# Automated Bash script to install and configure V2Ray with VLESS + WebSocket (WS) + TLS on Ubuntu 24.04 LTS. Uses Caddy v2 as a reverse proxy for automatic HTTPS certificate generation and management via Let's Encrypt. Designed for minimal user interaction, includes logging and error handling. Generates client configuration details, a VLESS share link, and a QR code upon successful setup, saving them to /root/. Requires a pre-configured domain name pointing to the server's IP and open firewall ports (TCP 80 & 443).
# Author: Awais Jameel
# Version: 1.0

# Executable Script: 
# Connect to your EC2 instance via SSH and download the script:
# wget https://raw.githubusercontent.com/awaisjameel/automation-scripts/main/vpn-proxy/v2ray-vless-ws-tls-caddy-auto-install-ubuntu.sh
# sudo chmod +x v2ray-vless-ws-tls-caddy-auto-install-ubuntu.sh
# sudo bash v2ray-vless-ws-tls-caddy-auto-install-ubuntu.sh

# --- Configuration ---
# You can change the path if you want, but ensure it's consistent.
WEBSOCKET_PATH="/vlws-$(openssl rand -hex 8)" # Random path for slightly better obfuscation
V2RAY_PORT="10001" # Internal port V2Ray listens on (Caddy proxies to this)
LOG_FILE="/var/log/v2ray_install.log"
# --- End Configuration ---

# --- Colors and Logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO] $(date +'%Y-%m-%d %H:%M:%S') - $1${NC}" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $(date +'%Y-%m-%d %H:%M:%S') - $1${NC}" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS] $(date +'%Y-%m-%d %H:%M:%S') - $1${NC}" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR] $(date +'%Y-%m-%d %H:%M:%S') - $1${NC}" | tee -a "$LOG_FILE"
}

# Exit on any error
set -e
# Log all commands (optional, noisy)
# set -x

# --- Pre-checks ---
# Check if running as root
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root. Use 'sudo bash $0'."
   exit 1
fi

# Check for Ubuntu 24.04 (adjust if necessary for other versions)
if ! grep -q "VERSION_ID=\"24.04\"" /etc/os-release; then
    log_warn "This script is designed for Ubuntu 24.04. It might work on other Debian-based systems but is not guaranteed."
fi

# Check for necessary commands
for cmd in curl wget openssl grep systemctl tee; do
    if ! command -v $cmd &> /dev/null; then
        log_error "$cmd is required but not found. Please install it (e.g., sudo apt install $cmd)."
        exit 1
    fi
done

# --- User Input ---
log_info "Starting V2Ray (VLESS+WS+TLS) setup..."
echo | tee -a "$LOG_FILE" # Newline in log

# Clear log file if it exists
> "$LOG_FILE"

read -p "Enter the domain name you have pointed to this server's IP: " DOMAIN_NAME
if [[ -z "$DOMAIN_NAME" ]]; then
    log_error "Domain name cannot be empty."
    exit 1
fi
# Basic domain validation
if ! echo "$DOMAIN_NAME" | grep -Pq '^(?!-)[a-zA-Z0-9-]{1,63}(?<!-)(\.(?!-)[a-zA-Z0-9-]{1,63}(?<!-))+$'; then
    log_error "Invalid domain name format entered: $DOMAIN_NAME"
    exit 1
fi
log_info "Using domain: $DOMAIN_NAME"
log_info "Using WebSocket path: $WEBSOCKET_PATH"
log_info "Using internal V2Ray port: $V2RAY_PORT"

# Get Public IP (for user confirmation)
PUBLIC_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || curl -s http://checkip.amazonaws.com)
if [[ -z "$PUBLIC_IP" ]]; then
    log_warn "Could not automatically determine public IP address."
    PUBLIC_IP="<unknown>"
fi

log_warn "----------------------------------------------------------------------"
log_warn "IMPORTANT PRE-REQUISITES:"
log_warn "1. Ensure your domain name '$DOMAIN_NAME'"
log_warn "   points to this server's public IP: $PUBLIC_IP"
log_warn "   (Check DNS propagation if you just set it up)."
log_warn "2. Ensure TCP ports 80 and 443 are OPEN in your AWS Security Group"
log_warn "   (or other firewall) allowing traffic from Anywhere (0.0.0.0/0)."
log_warn "----------------------------------------------------------------------"
read -p "Press Enter to continue if you have met these requirements, or Ctrl+C to abort..."

# --- Installation ---
log_info "Updating system packages..."
apt-get update > /dev/null 2>> "$LOG_FILE" && apt-get upgrade -y >> "$LOG_FILE" 2>&1
if [[ $? -ne 0 ]]; then
    log_error "Failed to update system packages. Check $LOG_FILE."
    exit 1
fi
log_success "System packages updated."

log_info "Installing Caddy and required tools (curl, unzip)..."
apt-get install -y curl unzip caddy >> "$LOG_FILE" 2>&1
if [[ $? -ne 0 ]]; then
    log_error "Failed to install Caddy or other dependencies. Check $LOG_FILE."
    exit 1
fi
log_success "Caddy and dependencies installed."

log_info "Downloading and installing V2Ray (Project V)..."
bash -c "$(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)" >> "$LOG_FILE" 2>&1
if [[ $? -ne 0 ]]; then
    log_error "Failed to install V2Ray. Check $LOG_FILE."
    # Attempt cleanup if install script failed partially
    systemctl disable --now v2ray > /dev/null 2>&1 || true
    rm -rf /usr/local/bin/v2ray /usr/local/bin/v2ctl /usr/local/etc/v2ray /etc/systemd/system/v2ray* /var/log/v2ray > /dev/null 2>&1 || true
    exit 1
fi
# Verify V2Ray executable exists
if ! command -v v2ray &> /dev/null; then
    log_error "V2Ray command not found after installation attempt. Installation failed."
    exit 1
fi
log_success "V2Ray installed."

# --- Configuration ---
log_info "Generating V2Ray UUID..."
V2RAY_UUID=$(v2ray uuid)
if [[ -z "$V2RAY_UUID" ]]; then
    log_error "Failed to generate V2Ray UUID."
    exit 1
fi
log_success "Generated V2Ray UUID: $V2RAY_UUID"

log_info "Configuring V2Ray (/usr/local/etc/v2ray/config.json)..."
cat <<EOF > /usr/local/etc/v2ray/config.json
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${V2RAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${V2RAY_UUID}",
            "level": 0,
            "email": "user@${DOMAIN_NAME}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${WEBSOCKET_PATH}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF
if [[ $? -ne 0 ]]; then
    log_error "Failed to write V2Ray config file."
    exit 1
fi
# Validate JSON (basic check)
if ! v2ray test -config /usr/local/etc/v2ray/config.json > /dev/null; then
     log_error "V2Ray configuration file is invalid. Check /usr/local/etc/v2ray/config.json"
     v2ray test -config /usr/local/etc/v2ray/config.json >> "$LOG_FILE" 2>&1 # Log actual error
     exit 1
fi
# Create V2Ray log directory and set permissions
mkdir -p /var/log/v2ray
chown -R nobody:nogroup /var/log/v2ray
log_success "V2Ray configuration created."

log_info "Configuring Caddy (/etc/caddy/Caddyfile)..."
# Stop Caddy before modifying config, prevent race conditions with auto-reload
systemctl stop caddy || true

# Backup existing Caddyfile if it exists and isn't a symlink
if [[ -f "/etc/caddy/Caddyfile" && ! -L "/etc/caddy/Caddyfile" ]]; then
    mv /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak.$(date +%s)
    log_info "Backed up existing Caddyfile."
fi

cat <<EOF > /etc/caddy/Caddyfile
{
    # Global options block
    email youremail@example.com # Optional: Replace with your email for Let's Encrypt notices
    admin off # Disable admin API for security unless needed
    log {
      output file /var/log/caddy/caddy.log {
          roll_size 10MiB
          roll_keep 5
      }
      level INFO # Set to DEBUG for more verbose logs if needed
    }
}

${DOMAIN_NAME} {
    # Enable TLS with automatic Let's Encrypt certificates
    tls youremail@example.com

    # Handle V2Ray WebSocket connections
    @vless_ws {
        path ${WEBSOCKET_PATH}
        header Connection *Upgrade*
        header Upgrade websocket
    }
    reverse_proxy @vless_ws 127.0.0.1:${V2RAY_PORT} {
         # Optional: Increase buffer sizes if experiencing issues with large transfers
         # transport http {
         #    read_buffer  4096
         #    write_buffer 4096
         # }
    }

    # Optional: Serve a basic page at the root to make it look like a real server
    # If you have a static site, replace this block with 'root * /path/to/your/site' and 'file_server'
    @root path /
    handle @root {
        respond "Service Active." 200 {
             close # Close connection immediately after response
        }
    }

    # Optional: Deny access to other paths
    # handle {
    #     abort
    # }

    # Log errors for this site
    log {
      output file /var/log/caddy/${DOMAIN_NAME}.log {
          roll_size 10MiB
          roll_keep 5
      }
      level ERROR
    }
}
EOF
if [[ $? -ne 0 ]]; then
    log_error "Failed to write Caddyfile."
    exit 1
fi
log_success "Caddy configuration created."

# --- Start Services ---
log_info "Reloading systemd daemon..."
systemctl daemon-reload

log_info "Enabling and restarting V2Ray service..."
systemctl enable v2ray >> "$LOG_FILE" 2>&1
systemctl restart v2ray
sleep 2 # Give service a moment to start

if ! systemctl is-active --quiet v2ray; then
    log_error "V2Ray service failed to start. Check status with 'sudo systemctl status v2ray' and logs in '/var/log/v2ray/error.log'."
    systemctl status v2ray --no-pager -l >> "$LOG_FILE" 2>&1
    exit 1
fi
log_success "V2Ray service started and enabled."

log_info "Enabling and restarting Caddy service..."
systemctl enable caddy >> "$LOG_FILE" 2>&1
systemctl restart caddy
sleep 5 # Give Caddy time to potentially obtain certificate

if ! systemctl is-active --quiet caddy; then
    log_error "Caddy service failed to start. Check status with 'sudo systemctl status caddy' and logs in '/var/log/caddy/caddy.log'."
    log_warn "Common causes: DNS not propagated yet, Port 80/443 blocked by firewall, or incorrect domain in Caddyfile."
    systemctl status caddy --no-pager -l >> "$LOG_FILE" 2>&1
    exit 1
fi
log_success "Caddy service started and enabled."

# --- Generate Client Config Files and QR Code --- # Replace the previous "Generate Client Config" section and the final echo lines with this

log_info "Preparing final configuration outputs..."

# Sanitize domain name for filenames (replace dots with underscores)
SANITIZED_DOMAIN=$(echo "$DOMAIN_NAME" | sed 's/\./_/g')
CONFIG_BASE_PATH="/root" # Save files in /root/ directory
CONFIG_DETAILS_FILE="${CONFIG_BASE_PATH}/vless_${SANITIZED_DOMAIN}_details.txt"
CONFIG_LINK_FILE="${CONFIG_BASE_PATH}/vless_${SANITIZED_DOMAIN}_link.txt"
CONFIG_QR_FILE="${CONFIG_BASE_PATH}/vless_${SANITIZED_DOMAIN}_qr.png"

# URL Encode Path (Ensure it's done correctly for the link)
# Simple sed replacement is usually okay for basic paths, but a more robust method could be used if needed.
encoded_path=$(printf '%s' "$WEBSOCKET_PATH" | sed 's|/|%2F|g') # Use printf for safety

# Generate the VLESS Link
VMESS_LINK="vless://${V2RAY_UUID}@${DOMAIN_NAME}:443?encryption=none&security=tls&type=ws&host=${DOMAIN_NAME}&path=${encoded_path}#${DOMAIN_NAME}_VLESS_WS_TLS"


# --- Install qrencode ---
QR_CODE_GENERATED=false
log_info "Checking for qrencode package..."
if ! command -v qrencode &> /dev/null; then
    log_info "qrencode not found, attempting installation..."
    # Run apt update non-interactively just in case package lists are stale
    DEBIAN_FRONTEND=noninteractive apt-get update -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" -qq > /dev/null 2>> "$LOG_FILE"
    DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" -qq >> "$LOG_FILE" 2>&1
    if [[ $? -ne 0 ]]; then
        log_error "Failed to install qrencode. QR code cannot be generated. Check $LOG_FILE."
        log_warn "You can try installing it manually: sudo apt update && sudo apt install qrencode"
    else
         log_success "qrencode installed successfully."
         QR_CODE_GENERATED=true
    fi
else
    log_info "qrencode is already installed."
    QR_CODE_GENERATED=true
fi

# --- Create Config Files ---
log_info "Saving configuration details to $CONFIG_DETAILS_FILE..."
# Use cat and heredoc for multi-line structured text file
cat << EOF > "$CONFIG_DETAILS_FILE"
############################################################
# V2Ray Client Configuration Details
# Server: ${DOMAIN_NAME}
# Generated on: $(date)
############################################################

# Connection Parameters:
# --------------------------------------------------
  Address (Server):     ${DOMAIN_NAME}
  Port:                 443
  UUID:                 ${V2RAY_UUID}
  AlterId / Level:      0
  Security (Encryption): none  (Note: Outer layer is secured by TLS)
  Network (Type):       ws (WebSocket)
  WebSocket Host:       ${DOMAIN_NAME}
  WebSocket Path:       ${WEBSOCKET_PATH}
  TLS:                  Enabled (tls)
  SNI (Server Name):    ${DOMAIN_NAME}
  Allow Insecure Cert:  false (Using valid Let's Encrypt cert via Caddy)

# VLESS Share Link (for clients supporting import):
# --------------------------------------------------
  ${VMESS_LINK}

############################################################
EOF
if [[ $? -ne 0 ]]; then log_warn "Could not write details to $CONFIG_DETAILS_FILE"; fi

log_info "Saving VLESS share link separately to $CONFIG_LINK_FILE..."
echo "${VMESS_LINK}" > "$CONFIG_LINK_FILE"
if [[ $? -ne 0 ]]; then log_warn "Could not write link to $CONFIG_LINK_FILE"; fi


# --- Generate QR Code ---
if [[ "$QR_CODE_GENERATED" = true ]]; then
    log_info "Generating QR code image..."
    qrencode -s 6 -l H -o "$CONFIG_QR_FILE" "${VMESS_LINK}" # -s size, -l error correction level (H=High), -o output file
    if [[ $? -eq 0 ]]; then
        log_success "QR code image saved to $CONFIG_QR_FILE"
        # Check if file exists and is readable
        if [[ ! -r "$CONFIG_QR_FILE" ]]; then
            log_warn "QR code file $CONFIG_QR_FILE was created but seems unreadable."
        fi
    else
        log_error "Failed to generate QR code image. Check $LOG_FILE."
        QR_CODE_GENERATED=false # Update status
    fi
fi

# --- Final Output to Console ---
echo -e "\n${GREEN}--- Installation Complete! ---${NC}\n" | tee -a "$LOG_FILE"
echo -e "${YELLOW}Reminder: Ensure TCP ports 80 and 443 are OPEN in your AWS Security Group (or other firewall).${NC}" | tee -a "$LOG_FILE"
echo -e "\n${GREEN}V2Ray Client Configuration Summary:${NC}" | tee -a "$LOG_FILE"
echo -e "--------------------------------------------------" | tee -a "$LOG_FILE"
echo -e " ${BLUE}Server Domain:${NC}   ${DOMAIN_NAME}" | tee -a "$LOG_FILE"
echo -e " ${BLUE}Port:${NC}          443" | tee -a "$LOG_FILE"
echo -e " ${BLUE}UUID:${NC}          ${V2RAY_UUID}" | tee -a "$LOG_FILE"
echo -e " ${BLUE}Transport:${NC}     WebSocket (WS) over TLS" | tee -a "$LOG_FILE"
echo -e " ${BLUE}WS Path:${NC}       ${WEBSOCKET_PATH}" | tee -a "$LOG_FILE"
echo -e " ${BLUE}WS Host/SNI:${NC}   ${DOMAIN_NAME}" | tee -a "$LOG_FILE"
echo -e "--------------------------------------------------" | tee -a "$LOG_FILE"
echo -e "\n${GREEN}Configuration Files Saved in ${CONFIG_BASE_PATH}:${NC}" | tee -a "$LOG_FILE"
echo -e "  - Detailed Config: ${YELLOW}${CONFIG_DETAILS_FILE}${NC}" | tee -a "$LOG_FILE"
echo -e "  - Share Link Only: ${YELLOW}${CONFIG_LINK_FILE}${NC}" | tee -a "$LOG_FILE"

# Only mention QR code file if it was successfully generated
if [[ "$QR_CODE_GENERATED" = true ]] && [[ -r "$CONFIG_QR_FILE" ]]; then
    echo -e "  - QR Code Image:   ${YELLOW}${CONFIG_QR_FILE}${NC}" | tee -a "$LOG_FILE"
    echo -e "\n${CYAN}You can view/download the QR code file using SCP or by serving it temporarily if needed.${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}Example using SCP (run from your local machine):${NC}" | tee -a "$LOG_FILE"
    echo -e "${YELLOW}scp -i /path/to/your/key.pem ubuntu@${PUBLIC_IP}:${CONFIG_QR_FILE} ./${NC}" | tee -a "$LOG_FILE" # Assumes PUBLIC_IP var is still available
elif [[ "$QR_CODE_GENERATED" = true ]]; then
     echo -e "  - QR Code Image:   ${RED}Failed to generate or verify QR Code file at ${CONFIG_QR_FILE}.${NC}" | tee -a "$LOG_FILE"
else
     echo -e "  - QR Code Image:   ${RED}Not generated (qrencode install failed or error occurred).${NC}" | tee -a "$LOG_FILE"
fi

echo -e "\n--------------------------------------------------" | tee -a "$LOG_FILE"
echo -e " ${GREEN}Import the VLESS Share Link into your client (e.g., V2RayNG, Shadowrocket):${NC}" | tee -a "$LOG_FILE"
echo -e " ${YELLOW}${VMESS_LINK}${NC}" | tee -a "$LOG_FILE"
echo -e "\n--------------------------------------------------" | tee -a "$LOG_FILE"
echo -e " Full installation log saved to: ${LOG_FILE}" | tee -a "$LOG_FILE"


exit 0