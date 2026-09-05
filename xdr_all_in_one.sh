#!/bin/bash
# ==============================================================
#  Kaspersky Next XDR & KUMA All-in-One Automated Installer
#  Release: Final Delivery (PoC Edition)
#  Status:  VERIFIED & WORKING (EDR - Ubuntu 22.04 / 24.04 LTS)
#  Updated: 2026-08-28
#  Location: /root/XDR/xdr_all_in_one.sh
#  Created by: Sherif Saleh
# 
#  IMPORTANT NOTICE:
#  THIS SCRIPT IS DESIGNED AND INTENDED STRICTLY FOR
#  PROOF OF CONCEPT (PoC) AND LAB VALIDATION PURPOSES ONLY.
# ==============================================================
set -e

export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="/root/XDR"
LOGFILE="/var/log/setup_script.log"
ENV_CACHE="/tmp/.xdr_vars.env"
KASPERSKY_BOX_TOKEN="4c9c629f3f36444ba0b1"
KASPERSKY_BOX_URL="https://box.kaspersky.com"

# ==============================================================
# 0. CONFIGURATION & ENVIRONMENT LOADING
# ==============================================================
CONFIG_FILE=""
if [ -f "$SCRIPT_DIR/config.env" ]; then
    CONFIG_FILE="$SCRIPT_DIR/config.env"
elif [ -f "$TARGET_DIR/config.env" ]; then
    CONFIG_FILE="$TARGET_DIR/config.env"
elif [ -f "$SCRIPT_DIR/download_links.txt" ]; then
    CONFIG_FILE="$SCRIPT_DIR/download_links.txt"
elif [ -f "$TARGET_DIR/download_links.txt" ]; then
    CONFIG_FILE="$TARGET_DIR/download_links.txt"
fi

if [ -n "$CONFIG_FILE" ]; then
    sed -i 's/\r$//' "$CONFIG_FILE"
    source "$CONFIG_FILE"
else
    mkdir -p "$TARGET_DIR"
    cat << 'CONFEOF' > "$TARGET_DIR/config.env"
TARGET_DIR="/root/XDR"
BIN_URL="https://products.s.kaspersky-labs.com/special/XDR/2.2.0.0/multilanguage-INT-2.2/95fca290119f478784efeabac1da0186/bin.tar.gz"
XDR_TAR_URL="https://products.s.kaspersky-labs.com/special/XDR/2.2.0.0/multilanguage-INT-2.2/english-INT/5aee259d0b2b4524b124b292a45c8694/xdr-2.2.448-en.tar"
PLUGIN_TAR_URL="https://aes.s.kaspersky-labs.com/b2b/KESforWin/14.1.0.6225/multilanguage-INT-6.0.0.6225/3fb2ef27e66f48698b5ebb51cf0b7625/plugin-kesw_14.1.0.6225.tar"
LICENSE_URL="https://box.kaspersky.com/seafhttp/f/941b883dd4fb4caf8bc0/?raw=1"
DEFAULT_HOST_IP=""
DEFAULT_INGRESS_IP=""
DEFAULT_DOMAIN_NAME="smp.subdomain.local"
DEFAULT_HOST_DOMAIN="xdr.subdomain.local"
ALL_SERVICES_IN_CLUSTER=""
UNIFIED_PASSWORD=""
CONFEOF
    source "$TARGET_DIR/config.env"
fi

TARGET_DIR="${TARGET_DIR:-/root/XDR}"
mkdir -p "$TARGET_DIR"

if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}Error: This script must be run as root (or with sudo).${NC}" 1>&2
    exit 1
fi

# ==============================================================
# Helper Functions
# ==============================================================
clear_all_caches() {
    echo -e "  ${YELLOW}Wiping temporary cache, previous state, and mount points...${NC}"
    
    # 1. Stop k0s processes if running
    if command -v k0s >/dev/null 2>&1; then
        k0s stop >/dev/null 2>&1 || true
        k0s reset --force >/dev/null 2>&1 || true
    fi
    systemctl stop k0scontroller >/dev/null 2>&1 || true

    # 2. Lazy unmount all active k0s and containerd filesystem mounts
    grep -E '/(run|var/lib)/k0s' /proc/mounts 2>/dev/null | awk '{print $2}' | sort -r | xargs -r umount -f -l 2>/dev/null || true

    # 3. Clean cache files and state directories
    rm -f /tmp/.xdr_vars.env
    rm -rf /root/.kdt /root/.kube /var/lib/k0s /etc/k0s /run/k0s /var/openebs
    rm -f "$TARGET_DIR"/singlenode.smp_param_*.yaml "$TARGET_DIR"/single.inventory_*.yml
    
    echo -e "  ${GREEN}✔ Cache cleared (clean deployment state).${NC}\n"
}

validate_ip() {
    local ip="$1"
    if expr "$ip" : '^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+$' >/dev/null 2>&1; then
        local o1 o2 o3 o4
        o1=$(echo "$ip" | cut -d'.' -f1)
        o2=$(echo "$ip" | cut -d'.' -f2)
        o3=$(echo "$ip" | cut -d'.' -f3)
        o4=$(echo "$ip" | cut -d'.' -f4)
        if [ "$o1" -le 255 ] && [ "$o2" -le 255 ] && [ "$o3" -le 255 ] && [ "$o4" -le 255 ]; then
            return 0
        fi
    fi
    return 1
}

download_if_missing() {
    local file_name="$1"
    local url="$2"
    local file_path="$TARGET_DIR/$file_name"

    if [ -s "$file_path" ]; then
        echo -e "  ${YELLOW}✔ [SKIPPED]${NC} $file_name already exists ($(du -h "$file_path" | cut -f1))"
    else
        echo -e "  ${CYAN}==> Downloading $file_name...${NC}"
        curl -C - -L -o "$file_path" "$url"
        if [ -s "$file_path" ]; then
            echo -e "  ${GREEN}✔ Downloaded $file_name successfully.${NC}"
        else
            echo -e "  ${RED}✖ Failed to download $file_name.${NC}"
            exit 1
        fi
    fi
}

collect_and_upload_logs() {
    echo -e "\n${CYAN}${BOLD}=============================================================="
    echo "         Diagnostic Logs & YAML Bundle Uploader               "
    echo "==============================================================${NC}"

    LATEST_KDT_LOG=$(ls -t /root/.kdt/bootstrap-*.log /root/.kdt/*.log 2>/dev/null | head -n 1)
    
    if [ -n "$LATEST_KDT_LOG" ] && [ -f "$LATEST_KDT_LOG" ]; then
        echo -e "  ${BOLD}Latest KDT Log:${NC} ${YELLOW}$LATEST_KDT_LOG${NC}"
        echo -e "  ${BOLD}Last 30 lines of log:${NC}"
        echo "----------------------------------------------------------------------"
        tail -n 30 "$LATEST_KDT_LOG"
        echo "----------------------------------------------------------------------"
    fi

    echo ""
    read -rp "$(echo -e "${BOLD}Package and upload logs and YAML files to Kaspersky Box? [Y/n]: ${NC}")" upload_choice
    upload_choice="${upload_choice:-Y}"

    case "$upload_choice" in
        [Yy]*)
            TIMESTAMP=$(date +%Y%m%d_%H%M%S)
            NODE_HNAME=$(hostname -s 2>/dev/null || echo "node")
            LOG_BUNDLE="$TARGET_DIR/xdr_diagnostics_${NODE_HNAME}_${TIMESTAMP}.tar.gz"
            
            echo -e "  ${CYAN}==> Packaging logs and YAML files into $LOG_BUNDLE...${NC}"
            
            YAML_FILES=$(ls "$TARGET_DIR"/*.yaml "$TARGET_DIR"/*.yml 2>/dev/null | xargs -n 1 basename 2>/dev/null || true)
            
            if [ -n "$YAML_FILES" ]; then
                tar -czf "$LOG_BUNDLE" \
                    -C / root/.kdt \
                    -C "$TARGET_DIR" $YAML_FILES \
                    -C /var/log setup_script.log 2>/dev/null || tar -czf "$LOG_BUNDLE" -C / root/.kdt 2>/dev/null || true
            else
                tar -czf "$LOG_BUNDLE" -C / root/.kdt -C /var/log setup_script.log 2>/dev/null || tar -czf "$LOG_BUNDLE" -C / root/.kdt 2>/dev/null || true
            fi

            echo -e "  ${GREEN}✔ Diagnostic archive created: ${BOLD}$LOG_BUNDLE${NC} ($(du -h "$LOG_BUNDLE" 2>/dev/null | cut -f1))"
            echo -e "  ${CYAN}==> Uploading bundle to Kaspersky Box...${NC}"
            
            python3 - <<PYUPLOAD
import os
import sys
import json
import ssl
import re
import subprocess
import urllib.request

bundle_path = "$LOG_BUNDLE"
token = "$KASPERSKY_BOX_TOKEN"
base_url = "$KASPERSKY_BOX_URL"
filename = os.path.basename(bundle_path)

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

headers = {
    'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'application/json, text/plain, */*'
}

upload_url = None

if not upload_url:
    try:
        url = f"{base_url}/api/v2.1/upload-links/{token}/upload-link/"
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            upload_url = data.get("upload_link")
    except Exception:
        pass

if not upload_url:
    try:
        url = f"{base_url}/api2/upload-links/{token}/upload-link/"
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            upload_url = data.get("upload_link")
    except Exception:
        pass

if not upload_url:
    try:
        url = f"{base_url}/u/d/{token}/"
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
            html = resp.read().decode('utf-8', errors='ignore')
            match = re.search(r'https?://[^"\']+/seafhttp/upload-[^"\']+', html)
            if match:
                upload_url = match.group(0)
            else:
                match_rel = re.search(r'/seafhttp/upload-[^"\']+', html)
                if match_rel:
                    upload_url = f"{base_url}{match_rel.group(0)}"
    except Exception:
        pass

if upload_url:
    print(f"\033[0;36m==> Uploading via Seafile HTTP API endpoint...\033[0m")
    cmd = ["curl", "-k", "--progress-bar", "-F", f"file=@{bundle_path}", "-F", f"filename={filename}", "-F", "parent_dir=/", upload_url]
    res = subprocess.run(cmd)
    if res.returncode == 0:
        print(f"\n\033[0;32m✔ Successfully uploaded {filename} to Kaspersky Box!\033[0m")
        print(f"\033[1;36m  Destination: {base_url}/u/d/{token}/\033[0m\n")
    else:
        print(f"\n\033[0;31m✖ Direct upload encountered a network error (curl exit code {res.returncode}).\033[0m")
        print(f"\033[1;33m  Manual upload link: {base_url}/u/d/{token}/\033[0m\n")
else:
    print(f"\033[0;33m==> Resolving upload URL directly via curl...\033[0m")
    raw_api = subprocess.run(["curl", "-k", "-s", "-H", "User-Agent: Mozilla/5.0", f"{base_url}/api/v2.1/upload-links/{token}/upload-link/"], capture_output=True, text=True)
    if '"upload_link"' in raw_api.stdout:
        m = re.search(r'"upload_link":\s*"([^"]+)"', raw_api.stdout)
        if m:
            upload_url = m.group(1).replace('\\/', '/')
            cmd = ["curl", "-k", "--progress-bar", "-F", f"file=@{bundle_path}", "-F", f"filename={filename}", "-F", "parent_dir=/", upload_url]
            res = subprocess.run(cmd)
            if res.returncode == 0:
                print(f"\n\033[0;32m✔ Successfully uploaded {filename} to Kaspersky Box!\033[0m\n")
                sys.exit(0)

    print(f"\033[0;32m✔ Diagnostic bundle is ready locally: {bundle_path}\033[0m")
    print(f"\033[1;33m  Manual upload link: {base_url}/u/d/{token}/\033[0m\n")
PYUPLOAD
            ;;
        *)
            echo -e "  ${YELLOW}Skipping log upload.${NC}"
            ;;
    esac
}

# ==============================================================
# POC NOTICE & BANNER
# ==============================================================
echo -e "${CYAN}${BOLD}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║    Kaspersky Next XDR & KUMA All-in-One Installer          ║"
echo "║    Status: VERIFIED & WORKING (EDR - Ubuntu 22.04/24.04)   ║"
echo "║                                                            ║"
echo "║    [!] NOTICE: THIS SCRIPT IS STRICTLY DESIGNED FOR        ║"
echo "║        PROOF OF CONCEPT (PoC) & LAB PURPOSES ONLY.         ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ==============================================================
# AUTOMATIC PRE-DEPLOYMENT CACHE CLEARING
# ==============================================================
echo -e "${YELLOW}${BOLD}==> Initializing clean deployment environment...${NC}"
clear_all_caches

# ==============================================================
# STEP 1: Parameter Collection & Unified Password
# ==============================================================
echo -e "${GREEN}${BOLD}[1/5] Collecting Deployment Parameters...${NC}"

DETECTED_IP="${DEFAULT_HOST_IP:-}"
if [ -z "$DETECTED_IP" ]; then
    DETECTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "$DETECTED_IP" ]; then
        DETECTED_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
    fi
    if [ -z "$DETECTED_IP" ]; then
        DETECTED_IP="10.0.0.42"
    fi
fi

while true; do
    read -rp "$(echo -e "${BOLD}1. Target Node Host IP (Format: X.X.X.X)${NC} [${YELLOW}$DETECTED_IP${NC}]: ")" input_host
    HOST_IP="${input_host:-$DETECTED_IP}"
    if validate_ip "$HOST_IP"; then
        break
    else
        echo -e "${RED}✖ Invalid IPv4 format. Try again.${NC}"
    fi
done

SUGG_INGRESS="${DEFAULT_INGRESS_IP:-10.0.0.182}"
while true; do
    read -rp "$(echo -e "${BOLD}2. Kubernetes Gateway / Ingress IP (Format: X.X.X.X)${NC} [${YELLOW}$SUGG_INGRESS${NC}]: ")" input_ingress
    INGRESS_IP="${input_ingress:-$SUGG_INGRESS}"
    if validate_ip "$INGRESS_IP"; then
        break
    else
        echo -e "${RED}✖ Invalid IPv4 format. Try again.${NC}"
    fi
done

SUGG_DOMAIN="${DEFAULT_DOMAIN_NAME:-smp.local}"
read -rp "$(echo -e "${BOLD}3. SMP Service Domain Name${NC} [${YELLOW}$SUGG_DOMAIN${NC}]: ")" input_domain
DOMAIN_NAME="${input_domain:-$SUGG_DOMAIN}"

SUGG_HOST_DOM="${DEFAULT_HOST_DOMAIN:-$DOMAIN_NAME}"
read -rp "$(echo -e "${BOLD}4. Host Domain Name (Machine FQDN & Inventory)${NC} [${YELLOW}$SUGG_HOST_DOM${NC}]: ")" input_host_domain
HOST_DOMAIN="${input_host_domain:-$SUGG_HOST_DOM}"

if [ -z "$ALL_SERVICES_IN_CLUSTER" ]; then
    read -rp "$(echo -e "${BOLD}5. Are all KUMA services installed inside the Kubernetes cluster? [Y/n]: ${NC}")" input_cluster_services
    input_cluster_services="${input_cluster_services:-Y}"
    case "$input_cluster_services" in
        [Yy]*) ALL_SERVICES_IN_CLUSTER="true" ;;
        *) ALL_SERVICES_IN_CLUSTER="false" ;;
    esac
fi

if [ "$ALL_SERVICES_IN_CLUSTER" = "true" ]; then
    echo -e "  ${GREEN}✔ In-Cluster Mode: 'inventory' and 'license' will be set to /dev/null.${NC}"
else
    echo -e "  ${GREEN}✔ Standard Deployment: 'inventory' and 'license' will link to local files.${NC}"
fi

if [ -z "$UNIFIED_PASSWORD" ]; then
    echo -e "\n${BOLD}6. Unified Master Password${NC} (Applied to SSH, PostgreSQL, XDR Admin, and Grafana):"
    echo -e "${YELLOW}Requirements: Minimum 10 characters, at least 3 categories (A-Z, a-z, 0-9, special symbols; no spaces or '.@')${NC}"
    while true; do
        read -rsp "$(echo -e "${BOLD}Enter Password (min 10 chars): ${NC}")" p1
        echo ""
        len="${#p1}"
        if [ "$len" -lt 10 ] || [ "$len" -gt 256 ]; then
            echo -e "${RED}✖ Password must be at least 10 characters long (KDT requirement). You entered $len characters. Try again.${NC}"
            continue
        fi
        case "$p1" in
            *" "*|*".@"*)
                echo -e "${RED}✖ Password cannot contain whitespace or '.@'. Try again.${NC}"
                continue
                ;;
        esac
        read -rsp "$(echo -e "${BOLD}Confirm Password: ${NC}")" p2
        echo ""
        if [ "$p1" != "$p2" ]; then
            echo -e "${RED}✖ Passwords do not match. Try again.${NC}"
            continue
        fi
        UNIFIED_PASSWORD="$p1"
        break
    done
else
    echo -e "  ${GREEN}✔ Using Unified Password from configuration file.${NC}"
fi

RAND_ID=$(shuf -i 10-99 -n 1)
echo -e "${GREEN}✔ Deployment ID: ${BOLD}${RAND_ID}${NC}"

# ==============================================================
# STEP 2: Early DNS Resolution Health Check
# ==============================================================
PRIMARY_NS=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || echo "127.0.0.53")

echo -e "\n${GREEN}${BOLD}[2/5] Verifying DNS Resolution (Nameserver: ${PRIMARY_NS})...${NC}"
echo "----------------------------------------------------------------------"
printf "%-35s %-16s %-16s %-10s\n" "FQDN" "Expected IP" "Resolved IP" "Status"
echo "----------------------------------------------------------------------"

TOTAL_DNS=0
PASSED_DNS=0

test_dns_record() {
    local fqdn="$1"
    local expected_ip="$2"
    TOTAL_DNS=$((TOTAL_DNS + 1))

    local resolved_ip=""
    if command -v host >/dev/null 2>&1; then
        resolved_ip=$(host -t A "$fqdn" "$PRIMARY_NS" 2>/dev/null | awk '/has address/ {print $4; exit}')
    elif command -v dig >/dev/null 2>&1; then
        resolved_ip=$(dig +short "$fqdn" @"$PRIMARY_NS" 2>/dev/null | head -n 1)
    elif command -v nslookup >/dev/null 2>&1; then
        resolved_ip=$(nslookup "$fqdn" "$PRIMARY_NS" 2>/dev/null | awk '/^Address: / {print $2}' | tail -n 1)
    fi

    if [ -z "$resolved_ip" ]; then
        resolved_ip=$(getent ahostsv4 "$fqdn" 2>/dev/null | awk '{print $1; exit}')
    fi
    if [ -z "$resolved_ip" ]; then
        resolved_ip=$(getent hosts "$fqdn" 2>/dev/null | awk '{print $1; exit}')
    fi

    if [ -z "$resolved_ip" ]; then
        printf "%-35s %-16s %-16s ${RED}%-10s${NC}\n" "$fqdn" "$expected_ip" "NOT RESOLVED" "✖ FAILED"
    elif [ "$resolved_ip" = "$expected_ip" ]; then
        printf "%-35s %-16s %-16s ${GREEN}%-10s${NC}\n" "$fqdn" "$expected_ip" "$resolved_ip" "✔ OK"
        PASSED_DNS=$((PASSED_DNS + 1))
    else
        printf "%-35s %-16s %-16s ${YELLOW}%-10s${NC}\n" "$fqdn" "$expected_ip" "$resolved_ip" "⚠ MISMATCH"
    fi
}

test_dns_record "console.${DOMAIN_NAME}"      "$INGRESS_IP"
test_dns_record "api.${DOMAIN_NAME}"          "$INGRESS_IP"
test_dns_record "kuma.${DOMAIN_NAME}"         "$INGRESS_IP"
test_dns_record "monitoring.${DOMAIN_NAME}"   "$INGRESS_IP"
test_dns_record "admsrv.${DOMAIN_NAME}"       "$INGRESS_IP"
test_dns_record "agentserver.${DOMAIN_NAME}"  "$INGRESS_IP"
test_dns_record "updater.${DOMAIN_NAME}"      "$INGRESS_IP"
test_dns_record "${HOST_DOMAIN}"              "$HOST_IP"

echo "----------------------------------------------------------------------"

if [ "$PASSED_DNS" -ne "$TOTAL_DNS" ]; then
    echo -e "${RED}✖ DNS Check: $PASSED_DNS/$TOTAL_DNS passed.${NC}"
    echo -e "\n${CYAN}${BOLD}Required DNS Records on your DNS Server (or /etc/hosts):${NC}"
    echo "$INGRESS_IP console.$DOMAIN_NAME api.$DOMAIN_NAME kuma.$DOMAIN_NAME monitoring.$DOMAIN_NAME admsrv.$DOMAIN_NAME agentserver.$DOMAIN_NAME updater.$DOMAIN_NAME"
    echo "$HOST_IP $HOST_DOMAIN"
    echo ""
    read -rp "$(echo -e "${BOLD}Do you want to continue despite DNS warnings? [y/N]: ${NC}")" dns_continue
    case "$dns_continue" in
        [Yy]*) ;;
        *)
            echo -e "${RED}Deployment aborted. Please configure DNS records and rerun.${NC}"
            exit 1
            ;;
    esac
else
    echo -e "${GREEN}✔ All 8 DNS records verified successfully.${NC}"
fi

# ==============================================================
# STEP 3: Smart Downloader
# ==============================================================
echo -e "\n${GREEN}${BOLD}[3/5] Checking Distribution Packages in $TARGET_DIR...${NC}"

download_if_missing "bin.tar.gz" "$BIN_URL"
download_if_missing "xdr-2.2.448-en.tar" "$XDR_TAR_URL"
download_if_missing "plugin-kesw_14.1.0.6225.tar" "$PLUGIN_TAR_URL"
download_if_missing "license.key" "$LICENSE_URL"

# ==============================================================
# STEP 4: OS Preparation, Updates & PostgreSQL 16 Setup
# ==============================================================
echo -e "\n${GREEN}${BOLD}[4/5] Executing OS Preparation & PostgreSQL 16 Setup...${NC}"

# 1. OS Version Check
if grep -q "Ubuntu" /etc/os-release; then
    VERSION=$(grep 'VERSION_ID' /etc/os-release | tr -d '"' | cut -d '=' -f 2 | cut -d '.' -f 1,2)
    if [ "$VERSION" != "22.04" ] && [ "$VERSION" != "24.04" ]; then
        echo -e "${RED}Error: Ubuntu 22.04 LTS or 24.04 LTS is required (Detected: $VERSION).${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✔ Supported Ubuntu version detected ($VERSION LTS).${NC}"
else
    echo -e "${RED}Error: Only Ubuntu 22.04 LTS and 24.04 LTS are supported.${NC}"
    exit 1
fi

# 2. Package Updates
echo -e "  ${GREEN}Updating and upgrading Ubuntu system packages...${NC}"
apt-get update -qq >/dev/null 2>&1
apt-get upgrade -y -qq >/dev/null 2>&1
echo -e "  ${GREEN}✔ Ubuntu system packages updated.${NC}"

# 3. Kernel Check
REQUIRED_KERNEL="5.15.0-118"
CURRENT_KERNEL=$(uname -r | sed 's/-generic//')
if dpkg --compare-versions "$CURRENT_KERNEL" "lt" "$REQUIRED_KERNEL"; then
    echo -e "${RED}Kernel $CURRENT_KERNEL is lower than $REQUIRED_KERNEL. Updating system...${NC}"
    apt update && apt upgrade -y
    echo -e "${RED}System updated. Please reboot and rerun.${NC}"
    exit 1
else
    echo -e "  ${GREEN}✔ Kernel version ($CURRENT_KERNEL) is suitable.${NC}"
fi

# 4. CPU Instructions
echo "  Checking CPU instruction support..."
if grep -m1 -q '\<avx[0-9]*\>' /proc/cpuinfo || grep -q -E 'avx|avx2|avx512' /proc/cpuinfo; then
    echo -e "  ${GREEN}✔ AVX support detected.${NC}"
else
    echo -e "${RED}✖ AVX support not detected.${NC}"
    exit 1
fi

if grep -q -E 'sse4_1|sse4_2|sse4a|sse4' /proc/cpuinfo; then
    echo -e "  ${GREEN}✔ SSE4 support detected.${NC}"
else
    echo -e "  ${YELLOW}⚠ SSE4 flag not explicitly found (continuing).${NC}"
fi

# 5. Resource Checks
REQUIRED_VCPU=8
REQUIRED_MEMORY=16
AVAILABLE_VCPU=$(nproc)
AVAILABLE_MEMORY=$(( $(free -g | awk 'NR==2{print $2}') + 1 ))

if [ "$AVAILABLE_VCPU" -lt "$REQUIRED_VCPU" ]; then
    echo -e "${RED}✖ Insufficient vCPU: Only ${AVAILABLE_VCPU} available, at least ${REQUIRED_VCPU} required.${NC}"
    exit 1
fi
if [ "$AVAILABLE_MEMORY" -lt "$REQUIRED_MEMORY" ]; then
    echo -e "${RED}✖ Insufficient RAM: Only ${AVAILABLE_MEMORY}GB available, at least ${REQUIRED_MEMORY}GB required.${NC}"
    exit 1
fi
echo -e "  ${GREEN}✔ Hardware resources: ${AVAILABLE_VCPU} vCPU, ${AVAILABLE_MEMORY}GB RAM.${NC}"

REQUIRED_SPACE_ROOT=200
AVAILABLE_SPACE_ROOT=$(df -BG --output=avail / | tail -n 1 | tr -dc '0-9')
if [ "$AVAILABLE_SPACE_ROOT" -lt "$REQUIRED_SPACE_ROOT" ]; then
    echo -e "${RED}✖ Insufficient disk space: Only ${AVAILABLE_SPACE_ROOT}GB available, at least ${REQUIRED_SPACE_ROOT}GB required.${NC}"
    exit 1
fi
echo -e "  ${GREEN}✔ Disk space: ${AVAILABLE_SPACE_ROOT}GB available.${NC}"

# 6. IPv6 & Firewall
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
sed -i '/:[0-9a-fA-F]\{1,4\}/d' /etc/hosts >/dev/null 2>&1 || true
systemctl stop ufw >/dev/null 2>&1 || true
systemctl disable ufw >/dev/null 2>&1 || true

# 7. Hostname & Hosts
sudo hostnamectl set-hostname "${HOST_DOMAIN}" >/dev/null 2>&1 || true

HOSTNAME_F=$(hostname -f)
if grep -q "#.*$HOSTNAME_F" /etc/hosts; then
    sed -i "/#.*$HOSTNAME_F/s/^#//" /etc/hosts
elif ! grep -q "$HOSTNAME_F" /etc/hosts; then
    echo "$HOST_IP $HOSTNAME_F" >> /etc/hosts
fi

# 8. SSH Server Config (Password & Key Auth)
echo -e "  ${GREEN}Configuring SSH server (Password Authentication & Root Login)...${NC}"
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

if [ -d /etc/ssh/sshd_config.d ]; then
    for conf in /etc/ssh/sshd_config.d/*.conf; do
        if [ -f "$conf" ]; then
            sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' "$conf"
            sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' "$conf"
        fi
    done
fi

echo "root:$UNIFIED_PASSWORD" | chpasswd
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

# 9. Local Keypair Setup & Verification
mkdir -p /root/.ssh
if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" >/dev/null 2>&1
fi
cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
chmod 700 /root/.ssh

ssh-keyscan -H "$HOST_IP" 127.0.0.1 localhost 2>/dev/null >> /root/.ssh/known_hosts || true
sort -u /root/.ssh/known_hosts -o /root/.ssh/known_hosts 2>/dev/null || true

if ssh -i /root/.ssh/id_rsa -o StrictHostKeyChecking=no -o BatchMode=yes root@127.0.0.1 "echo OK" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✔ Root account active and local SSH authentication verified.${NC}"
else
    echo -e "  ${YELLOW}⚠ Warning: Local SSH key self-test could not verify immediate login.${NC}"
fi

# 10. Required Packages & Chrony
apt-get install -y -qq curl docker.io python3 chrony sshpass >/dev/null 2>&1
systemctl enable --now chrony >/dev/null 2>&1 || true

# 11. PostgreSQL 16 Installation & Tuning
echo -e "  ${GREEN}Installing & tuning PostgreSQL 16...${NC}"
if command -v psql >/dev/null 2>&1; then
    CURRENT_PG_VER=$(psql -V 2>/dev/null | grep -oE '[0-9]+' | head -n 1)
    if [ "$CURRENT_PG_VER" != "16" ]; then
        echo -e "  ${YELLOW}Detected PostgreSQL version $CURRENT_PG_VER. Removing conflicting version...${NC}"
        systemctl stop postgresql* 2>/dev/null || true
        apt-get purge -y --allow-change-held-packages "postgresql*" >/dev/null 2>&1 || true
        rm -rf /etc/postgresql /var/lib/postgresql /var/log/postgresql 2>/dev/null || true
        apt-get autoremove -y >/dev/null 2>&1 || true
        echo -e "  ${GREEN}✔ Cleaned up older PostgreSQL installation.${NC}"
    fi
fi

wget -qO - https://www.postgresql.org/media/keys/ACCC4CF8.asc | tee /etc/apt/trusted.gpg.d/postgresql.asc >/dev/null
echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | tee /etc/apt/sources.list.d/pgdg.list >/dev/null
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq postgresql-16 postgresql-contrib-16 postgresql-client >/dev/null 2>&1
systemctl enable postgresql >/dev/null 2>&1
systemctl start postgresql >/dev/null 2>&1

PG_CONF=$(sudo -u postgres psql -t -P format=unaligned -c "SHOW config_file;" 2>/dev/null)
PG_DIR=$(dirname "$PG_CONF")
PG_HBA="$PG_DIR/pg_hba.conf"

sed -i "s/^#listen_addresses.*/listen_addresses = '*'/" "$PG_CONF"
sed -i "s/^#port = 5432/port = 5432/" "$PG_CONF"

sudo -u postgres psql <<'EOF' >/dev/null 2>&1
ALTER SYSTEM SET shared_buffers = '3GB';
ALTER SYSTEM SET effective_cache_size = '4GB';
ALTER SYSTEM SET maintenance_work_mem = '128MB';
ALTER SYSTEM SET work_mem = '16MB';
ALTER SYSTEM SET temp_buffers = '24MB';
ALTER SYSTEM SET max_parallel_workers_per_gather = 0;
ALTER SYSTEM SET max_connections = '512';
EOF

systemctl restart postgresql

sed -i "/0.0.0.0\/0/d" "$PG_HBA"
sed -i "/::\/0/d" "$PG_HBA"
cat <<EOF >> "$PG_HBA"
host    all     all     0.0.0.0/0     scram-sha-256
host    all     all     ::/0          scram-sha-256
EOF
systemctl reload postgresql

sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '$UNIFIED_PASSWORD';" >/dev/null 2>&1
sudo -u postgres psql -d postgres -c "CREATE EXTENSION IF NOT EXISTS btree_gin;" >/dev/null 2>&1
echo -e "  ${GREEN}✔ PostgreSQL 16 ready with unified password.${NC}"

# ==============================================================
# STEP 5: YAML Generation & KDT Deployment Launch
# ==============================================================
echo -e "\n${GREEN}${BOLD}[5/5] Generating YAML Files & Launching KDT Deployment...${NC}"

python3 - <<PYEOF
import os
from urllib.parse import quote_plus

host_ip = "$HOST_IP"
ingress_ip = "$INGRESS_IP"
domain = "$DOMAIN_NAME"
host_domain = "$HOST_DOMAIN"
master_pwd = """$UNIFIED_PASSWORD"""
rand_id = "$RAND_ID"
target_dir = "$TARGET_DIR"
all_in_cluster = "$ALL_SERVICES_IN_CLUSTER" == "true"

encoded_pwd = quote_plus(master_pwd)
psql_dsn = f"postgres://postgres:{encoded_pwd}@{host_ip}:5432"

inventory_file = os.path.join(target_dir, f"single.inventory_{rand_id}.yml")
smp_param_file = os.path.join(target_dir, f"singlenode.smp_param_{rand_id}.yaml")
license_file = os.path.join(target_dir, "license.key")

if all_in_cluster:
    inventory_val = "/dev/null"
    license_val = "/dev/null"
else:
    inventory_val = inventory_file
    license_val = license_file

# 1. singlenode.smp_param_<RAND_ID>.yaml (Clean KDT 2.2 schema)
smp_param_content = f"""# For more information about the installation parameters listed below, refer to Online Help.
schemaType: ParameterSet
schemaVersion: 1.0.1
namespace: ""
name: bootstrap
project: xdr
nodes:
  - desc: cdt-1
    type: primary-worker
    host: {host_ip}
    access:
      ssh:
        user: root
        key: /root/.ssh/id_rsa
parameters:
  - name: psql_dsn
    source:
      value: "{psql_dsn}"
  - name: ingress_ip
    source:
      value: {ingress_ip}
  - name: ssh_pk
    source:
      path: /root/.ssh/id_rsa
  - name: admin_password
    source:
      value: '{master_pwd}'
  - name: low_resources
    source:
      value: "true"
  - name: default_class_replica_count
    source:
      value: "1"
  - name: openbao_ha_mode
    source:
      value: "false"
  - name: inventory
    source:
      value: "{inventory_val}"
  - name: license
    source:
      value: "{license_val}"
  - name: smp_domain
    source:
      value: "{domain}"
  - name: pki_host_list
    source:
      value: "admsrv api console kuma monitoring"
  - name: autodeploy_plan
    source:
      value: "edr"
  - name: grafana_admin_user
    source:
      value: "admin"
  - name: grafana_admin_password
    source:
      value: '{master_pwd}'

"""

# 2. single.inventory_<RAND_ID>.yml
inventory_content = f"""all:
  vars:
    deploy_example_services: true
    ansible_connection: local
    ansible_user: nonroot
kuma:
  vars:
    ansible_connection: ssh
    ansible_user: root
  children:
    kuma_utils:
      hosts:
        {host_domain}:
          ansible_host: {host_ip}
    kuma_collector:
      hosts:
        {host_domain}:
          ansible_host: {host_ip}
    kuma_correlator:
      hosts:
        {host_domain}:
          ansible_host: {host_ip}
    kuma_storage:
      hosts:
        {host_domain}:
          ansible_host: {host_ip}
          shard: 1
          replica: 1
          keeper: 1
"""

with open(smp_param_file, "w", encoding="utf-8") as f:
    f.write(smp_param_content)

if not all_in_cluster:
    with open(inventory_file, "w", encoding="utf-8") as f:
        f.write(inventory_content)
    print(f"  ✔ Created Inventory YAML: {inventory_file}")
else:
    print(f"  ✔ In-Cluster Mode: 'inventory' and 'license' set to /dev/null.")

print(f"  ✔ Created Parameter YAML: {smp_param_file}")
PYEOF

SMP_PARAM_FILE="$TARGET_DIR/singlenode.smp_param_${RAND_ID}.yaml"
XDR_TAR=$(ls -t "$TARGET_DIR"/xdr-*.tar 2>/dev/null | head -n 1)
if [ -z "$XDR_TAR" ]; then
    XDR_TAR="$TARGET_DIR/xdr-2.2.448-en.tar"
fi

cd "$TARGET_DIR"
tar -xvf "$TARGET_DIR/bin.tar.gz" -C "$TARGET_DIR"

if [ -f "$TARGET_DIR/bin/kdt" ]; then
    mv -f "$TARGET_DIR/bin/kdt" "$TARGET_DIR/kdt"
elif [ -f "./bin/kdt" ]; then
    mv -f "./bin/kdt" "$TARGET_DIR/kdt"
fi
chmod +x "$TARGET_DIR/kdt"

# Clean up previous installation artifacts
echo -e "  ${YELLOW}Checking for and removing any previous installation state (./kdt remove --all)...${NC}"
REMOVE_OUTPUT=$(echo "yes" | "$TARGET_DIR/kdt" remove --all --allow-root 2>&1 || true)
if echo "$REMOVE_OUTPUT" | grep -q "bootstrap is not installed"; then
    echo -e "  ${GREEN}✔ Clean state ready for deployment.${NC}"
else
    echo -e "  ${GREEN}✔ Previous installation removed cleanly.${NC}"
fi

echo -e "\n${CYAN}${BOLD}=============================================================="
echo " Ready to deploy Kaspersky Next XDR Single-Node Cluster"
echo " Location:         $TARGET_DIR"
echo " Package Archive:  $XDR_TAR"
echo " Parameter File:   $SMP_PARAM_FILE"
echo -e "==============================================================${NC}"

read -rp "$(echo -e "${BOLD}Start KDT deployment now? [Y/n]: ${NC}")" confirm
confirm="${confirm:-Y}"

case "$confirm" in
    [Yy]*)
        echo -e "\n${GREEN}${BOLD}==> Launching KDT Apply with '--allow-root --accept-eula'...${NC}\n"
        KDT_SUCCESS=false
        PRIMARY_CMD="$TARGET_DIR/kdt apply -k $XDR_TAR -i $SMP_PARAM_FILE --accept-eula --allow-root"
        
        if eval "$PRIMARY_CMD"; then
            KDT_SUCCESS=true
        fi

        # Fallback Command Editor if apply failed
        if [ "$KDT_SUCCESS" != "true" ]; then
            echo -e "\n${RED}${BOLD}✖ KDT execution encountered an error.${NC}"
            echo -e "${YELLOW}Last executed command was:${NC}"
            echo -e "  ${CYAN}$PRIMARY_CMD${NC}\n"
            echo -e "${YELLOW}You can review, edit, or customize the command below to execute:${NC}"
            
            while true; do
                echo ""
                read -rp "$(echo -e "${BOLD}Edit/Confirm command [Press Enter to run]:${NC}\n${CYAN}$PRIMARY_CMD${NC}\n> ")" user_cmd
                CMD_TO_RUN="${user_cmd:-$PRIMARY_CMD}"
                echo -e "\n${GREEN}==> Executing: $CMD_TO_RUN${NC}\n"
                if eval "$CMD_TO_RUN"; then
                    echo -e "\n${GREEN}${BOLD}✔ Deployment command completed successfully!${NC}\n"
                    KDT_SUCCESS=true
                    break
                else
                    echo -e "\n${RED}✖ Command failed.${NC}"
                    read -rp "Would you like to edit and retry again? [Y/n]: " retry_choice
                    case "$retry_choice" in
                        [Nn]*) break ;;
                    esac
                fi
            done
        fi

        # Offer log collection if deployment failed
        if [ "$KDT_SUCCESS" != "true" ]; then
            echo -e "\n${RED}${BOLD}✖ Deployment was not completed.${NC}"
            collect_and_upload_logs
        else
            echo -e "\n${GREEN}${BOLD}✔ Deployment process completed successfully!${NC}\n"
        fi
        ;;
    *)
        echo -e "\n${YELLOW}Deployment paused. Launch manually anytime with:${NC}"
        echo "$TARGET_DIR/kdt apply -k $XDR_TAR -i $SMP_PARAM_FILE --accept-eula --allow-root"
        ;;
esac