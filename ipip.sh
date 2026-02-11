#!/bin/bash

# --- Color Codes ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=== Switch to IPIP Tunnel (Stability Fix) ===${NC}"

# 1. Define Paths
SCRIPT_PATH="/usr/local/bin/setup_tunnel.sh"
CONFIG_FILE="/etc/tunnel_config.env"
SERVICE_FILE="/etc/systemd/system/gre-tunnel.service"

# 2. Configuration Handling
if [ -f "$CONFIG_FILE" ]; then
    echo "Loading existing configuration..."
    source "$CONFIG_FILE"
else
    # Fallback if config is missing
    DEFAULT_LOCAL_IP=$(ip route get 1 | awk '{print $7;exit}')
    read -p "Local Server Public IP [$DEFAULT_LOCAL_IP]: " LOCAL_IP
    LOCAL_IP=${LOCAL_IP:-$DEFAULT_LOCAL_IP}
    read -p "Remote MikroTik Public IP: " REMOTE_IP
    read -p "Tunnel Interface Name [tun1]: " TUN_NAME
    TUN_NAME=${TUN_NAME:-tun1}
    read -p "Tunnel Internal IP (e.g., 192.168.16.1/30): " TUNNEL_IP_CIDR
    read -p "Excluded Ports [22]: " EXCLUDE_PORTS
    EXCLUDE_PORTS=${EXCLUDE_PORTS:-22}

    # Save
    echo "LOCAL_IP=\"$LOCAL_IP\"" > $CONFIG_FILE
    echo "REMOTE_IP=\"$REMOTE_IP\"" >> $CONFIG_FILE
    echo "TUN_NAME=\"$TUN_NAME\"" >> $CONFIG_FILE
    echo "TUNNEL_IP_CIDR=\"$TUNNEL_IP_CIDR\"" >> $CONFIG_FILE
    echo "EXCLUDE_PORTS=\"$EXCLUDE_PORTS\"" >> $CONFIG_FILE
fi

# 3. Create the Tunnel Script (IPIP PROTOCOL)
echo -e "${GREEN}[1/3] Creating IPIP Tunnel Script...${NC}"

cat <<EOF > $SCRIPT_PATH
#!/bin/bash
source $CONFIG_FILE

# Enable IP Forwarding
sysctl -w net.ipv4.ip_forward=1 > /dev/null

# Cleanup Old Tunnels (Both GRE and IPIP names to be safe)
ip link set gre1 down 2>/dev/null
ip tunnel del gre1 2>/dev/null
ip link set \$TUN_NAME down 2>/dev/null
ip tunnel del \$TUN_NAME 2>/dev/null

# Cleanup Firewall
iptables -t mangle -F OUTPUT
iptables -t nat -F POSTROUTING

# --- Create IPIP Tunnel ---
# Note: mode is now 'ipip' instead of 'gre'
ip tunnel add \$TUN_NAME mode ipip local \$LOCAL_IP remote \$REMOTE_IP ttl 255
ip link set \$TUN_NAME mtu 1280 up
ip addr add \$TUNNEL_IP_CIDR dev \$TUN_NAME

# Firewall Rules
# 1. Critical Ports (Direct)
iptables -t mangle -A OUTPUT -p tcp -m multiport --sports \$EXCLUDE_PORTS -j RETURN
iptables -t mangle -A OUTPUT -p udp -m multiport --sports \$EXCLUDE_PORTS -j RETURN
iptables -t mangle -A OUTPUT -p icmp -j RETURN

# 2. Anti-Loop (Direct)
iptables -t mangle -A OUTPUT -d \$REMOTE_IP -j RETURN
# Note: IPIP uses protocol 4 (ipencap), usually not needed to exclude specifically if destination IP is excluded, but let's be safe:
iptables -t mangle -A OUTPUT -p 4 -j RETURN

# 3. Mark Tunnel Traffic
iptables -t mangle -A OUTPUT -j MARK --set-mark 100

# 4. Fix Packet Size (Strict MSS 1200)
# This is lower than before to guarantee stability
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o \$TUN_NAME -j TCPMSS --set-mss 1200

# 5. NAT
iptables -t nat -A POSTROUTING -o \$TUN_NAME -j MASQUERADE

# Routing Logic
ip rule del fwmark 100 table 100 > /dev/null 2>&1
ip rule add fwmark 100 table 100
ip route replace default dev \$TUN_NAME table 100

# Explicit Route for Remote IP (To prevent any loop possibility)
DEFAULT_GW=\$(ip route show default | awk '{print \$3}')
ip route add \$REMOTE_IP via \$DEFAULT_GW 2>/dev/null

echo "IPIP Tunnel configured (MTU 1280 / MSS 1200)."
EOF

chmod +x $SCRIPT_PATH

# 4. Create Systemd Service with Restart Logic
echo -e "${GREEN}[2/3] Updating Systemd Service...${NC}"

cat <<EOF > $SERVICE_FILE
[Unit]
Description=IPIP Tunnel Service
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

# 5. Apply Changes
echo -e "${GREEN}[3/3] Applying IPIP Protocol...${NC}"
systemctl daemon-reload
systemctl enable gre-tunnel
systemctl restart gre-tunnel

echo ""
echo -e "${BLUE}=== SWITCH COMPLETE ===${NC}"
echo "Moved from GRE to IPIP."
echo "Check status: systemctl status gre-tunnel"
echo "NOTE: Please update your MikroTik interface to IPIP as well!"
EOF