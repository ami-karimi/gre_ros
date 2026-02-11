#!/bin/bash

# --- Color Codes ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=== GRE Tunnel Service Installer ===${NC}"

# 1. Prepare Paths
SCRIPT_PATH="/usr/local/bin/setup_tunnel.sh"
CONFIG_FILE="/etc/tunnel_config.env"
SERVICE_FILE="/etc/systemd/system/gre-tunnel.service"

# 2. Ask for Configuration (One Time)
echo -e "${GREEN}[1/4] Configuring Network Settings...${NC}"

if [ -f "$CONFIG_FILE" ]; then
    echo "Configuration file already exists at $CONFIG_FILE."
    read -p "Do you want to overwrite it? (y/n): " OVERWRITE
    if [[ "$OVERWRITE" != "y" ]]; then
        echo "Using existing configuration."
        SKIP_CONFIG=true
    fi
fi

if [ "$SKIP_CONFIG" != "true" ]; then
    DEFAULT_LOCAL_IP=$(ip route get 1 | awk '{print $7;exit}')
    read -p "Local Server Public IP [$DEFAULT_LOCAL_IP]: " LOCAL_IP
    LOCAL_IP=${LOCAL_IP:-$DEFAULT_LOCAL_IP}

    while [[ -z "$REMOTE_IP" ]]; do
        read -p "Remote MikroTik Public IP: " REMOTE_IP
    done

    read -p "Tunnel Interface Name [gre1]: " TUN_NAME
    TUN_NAME=${TUN_NAME:-gre1}

    read -p "Tunnel Internal IP (e.g., 192.168.16.1/30): " TUNNEL_IP_CIDR

    read -p "Excluded Ports (SSH, etc) [22]: " EXCLUDE_PORTS
    EXCLUDE_PORTS=${EXCLUDE_PORTS:-22}

    # Save Config
    echo "LOCAL_IP=\"$LOCAL_IP\"" > $CONFIG_FILE
    echo "REMOTE_IP=\"$REMOTE_IP\"" >> $CONFIG_FILE
    echo "TUN_NAME=\"$TUN_NAME\"" >> $CONFIG_FILE
    echo "TUNNEL_IP_CIDR=\"$TUNNEL_IP_CIDR\"" >> $CONFIG_FILE
    echo "EXCLUDE_PORTS=\"$EXCLUDE_PORTS\"" >> $CONFIG_FILE
    echo "Config saved to $CONFIG_FILE"
fi

# 3. Create the Main Script
echo -e "${GREEN}[2/4] Creating the Tunnel Script...${NC}"

cat <<EOF > $SCRIPT_PATH
#!/bin/bash
source $CONFIG_FILE

# Enable IP Forwarding
sysctl -w net.ipv4.ip_forward=1 > /dev/null

# Cleanup
if ip link show \$TUN_NAME > /dev/null 2>&1; then
    ip link set \$TUN_NAME down
    ip tunnel del \$TUN_NAME
fi
iptables -t mangle -F OUTPUT
iptables -t nat -F POSTROUTING

# Create Tunnel
ip tunnel add \$TUN_NAME mode gre local \$LOCAL_IP remote \$REMOTE_IP ttl 255
ip link set \$TUN_NAME mtu 1476 up
ip addr add \$TUNNEL_IP_CIDR dev \$TUN_NAME

# Firewall Rules
# 1. Allow Critical Ports (Direct)
iptables -t mangle -A OUTPUT -p tcp -m multiport --sports \$EXCLUDE_PORTS -j RETURN
iptables -t mangle -A OUTPUT -p udp -m multiport --sports \$EXCLUDE_PORTS -j RETURN
iptables -t mangle -A OUTPUT -p icmp -j RETURN

# 2. Anti-Loop (Direct)
iptables -t mangle -A OUTPUT -d \$REMOTE_IP -j RETURN
iptables -t mangle -A OUTPUT -p gre -j RETURN

# 3. Mark Tunnel Traffic
iptables -t mangle -A OUTPUT -j MARK --set-mark 100

# 4. Fix Packet Size & NAT
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o \$TUN_NAME -j TCPMSS --clamp-mss-to-pmtu
iptables -t nat -A POSTROUTING -o \$TUN_NAME -j MASQUERADE

# Routing
ip rule del fwmark 100 table 100 > /dev/null 2>&1
ip rule add fwmark 100 table 100
ip route replace default dev \$TUN_NAME table 100

echo "Tunnel configured successfully."
EOF

chmod +x $SCRIPT_PATH

# 4. Create Systemd Service
echo -e "${GREEN}[3/4] Creating Systemd Service...${NC}"

cat <<EOF > $SERVICE_FILE
[Unit]
Description=GRE Tunnel Setup Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 5. Enable and Start
echo -e "${GREEN}[4/4] Enabling and Starting Service...${NC}"
systemctl daemon-reload
systemctl enable gre-tunnel
systemctl start gre-tunnel

echo ""
echo -e "${BLUE}=== INSTALLATION COMPLETE ===${NC}"
echo "Check status with: systemctl status gre-tunnel"
EOF