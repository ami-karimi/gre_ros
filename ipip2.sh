#!/bin/bash

# --- Color Codes ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}=== Internal Network IPIP Tunnel Installer (Anti-Loop) ===${NC}"

# 1. Define Paths
SCRIPT_PATH="/usr/local/bin/setup_tunnel.sh"
CONFIG_FILE="/etc/tunnel_config.env"
SERVICE_FILE="/etc/systemd/system/ipip-tunnel.service"

# 2. Configuration Handling
echo -e "${GREEN}[1/4] Configuring Network Settings...${NC}"

if [ -f "$CONFIG_FILE" ]; then
    echo "Configuration file found at $CONFIG_FILE."
    source "$CONFIG_FILE"
    # Allow user to reset config
    read -p "Do you want to re-enter IPs? (y/n) [n]: " RESET_CONFIG
    if [[ "$RESET_CONFIG" == "y" ]]; then
        rm "$CONFIG_FILE"
        exec "$0" # Restart script
    fi
else
    # Auto-detect Local IP
    DEFAULT_LOCAL_IP=$(ip route get 1 | awk '{print $7;exit}')

    echo -e "${YELLOW}Please enter the IP addresses for the INTERNAL network connection:${NC}"
    read -p "Local Linux IP [$DEFAULT_LOCAL_IP]: " LOCAL_IP
    LOCAL_IP=${LOCAL_IP:-$DEFAULT_LOCAL_IP}

    while [[ -z "$REMOTE_IP" ]]; do
        read -p "Remote MikroTik IP: " REMOTE_IP
    done

    read -p "Tunnel Interface Name [tun1]: " TUN_NAME
    TUN_NAME=${TUN_NAME:-tun1}

    read -p "Tunnel Internal IP (e.g., 172.16.1.1/30): " TUNNEL_IP_CIDR
    while [[ -z "$TUNNEL_IP_CIDR" ]]; do
         read -p "Tunnel Internal IP is required: " TUNNEL_IP_CIDR
    done

    # Save Config
    echo "LOCAL_IP=\"$LOCAL_IP\"" > $CONFIG_FILE
    echo "REMOTE_IP=\"$REMOTE_IP\"" >> $CONFIG_FILE
    echo "TUN_NAME=\"$TUN_NAME\"" >> $CONFIG_FILE
    echo "TUNNEL_IP_CIDR=\"$TUNNEL_IP_CIDR\"" >> $CONFIG_FILE
fi

# 3. Create the Tunnel Script (High Performance IPIP)
echo -e "${GREEN}[2/4] Creating Tunnel Script...${NC}"

cat <<EOF > $SCRIPT_PATH
#!/bin/bash
source $CONFIG_FILE

# Enable IP Forwarding
sysctl -w net.ipv4.ip_forward=1 > /dev/null

# Cleanup Old Tunnels (Safety Check)
ip link set \$TUN_NAME down 2>/dev/null
ip tunnel del \$TUN_NAME 2>/dev/null
# Clean old GRE if exists
ip link set gre1 down 2>/dev/null
ip tunnel del gre1 2>/dev/null

# Cleanup Firewall
iptables -t mangle -F OUTPUT
iptables -t nat -F POSTROUTING

# --- 1. PREVENT LOOP (CRITICAL STEP) ---
# Find the default gateway interface
DEFAULT_GW=\$(ip route show default | awk '{print \$3}')
DEFAULT_IF=\$(ip route show default | awk '{print \$5}')

# Force route to Remote MikroTik via Physical Interface
ip route delete \$REMOTE_IP 2>/dev/null
if [ -n "\$DEFAULT_GW" ]; then
    ip route add \$REMOTE_IP via \$DEFAULT_GW dev \$DEFAULT_IF
else
    ip route add \$REMOTE_IP dev \$DEFAULT_IF
fi

# --- 2. Create IPIP Tunnel ---
# MTU 1400 is safe for internal networks (Standard is 1500, minus 20 bytes header = 1480, but 1400 is safer)
ip tunnel add \$TUN_NAME mode ipip local \$LOCAL_IP remote \$REMOTE_IP ttl 64
ip link set \$TUN_NAME mtu 1400 up
ip addr add \$TUNNEL_IP_CIDR dev \$TUN_NAME

# --- 3. Firewall Rules ---

# A) Exclude Critical Traffic (SSH, Mgmt)
iptables -t mangle -A OUTPUT -p tcp --sport 22 -j RETURN
iptables -t mangle -A OUTPUT -p icmp -j RETURN

# B) ANTI-LOOP (Extra Safety Layer)
# Do not mark IPIP protocol (4)
iptables -t mangle -A OUTPUT -p 4 -j RETURN
# Do not mark traffic destined to MikroTik Physical IP
iptables -t mangle -A OUTPUT -d \$REMOTE_IP -j RETURN

# C) Mark Tunnel Traffic
iptables -t mangle -A OUTPUT -j MARK --set-mark 100

# D) MSS Clamping (Optimized for Internal Network)
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o \$TUN_NAME -j TCPMSS --clamp-mss-to-pmtu

# E) NAT
iptables -t nat -A POSTROUTING -o \$TUN_NAME -j MASQUERADE

# --- 4. Routing ---
ip rule del fwmark 100 table 100 > /dev/null 2>&1
ip rule add fwmark 100 table 100
ip route replace default dev \$TUN_NAME table 100

echo "Internal IPIP Tunnel Configured (Target: \$REMOTE_IP)"
EOF

chmod +x $SCRIPT_PATH

# 4. Create Systemd Service
echo -e "${GREEN}[3/4] Creating Systemd Service...${NC}"

cat <<EOF > $SERVICE_FILE
[Unit]
Description=Internal IPIP Tunnel Service
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
echo -e "${GREEN}[4/4] Applying Changes...${NC}"
systemctl daemon-reload
systemctl enable ipip-tunnel
systemctl restart ipip-tunnel

# --- Calculate MikroTik IP ---
# Simple logic to guess MikroTik side IP (assumes /30 subnet)
# If Linux is .1, MikroTik is likely .2
IFS='/' read -r IP_ADDR SUBNET <<< "\$TUNNEL_IP_CIDR"
IFS='.' read -r i1 i2 i3 i4 <<< "\$IP_ADDR"
if [ "\$i4" -eq 1 ]; then MIKROTIK_TUN_IP="\$i1.\$i2.\$i3.2"; else MIKROTIK_TUN_IP="\$i1.\$i2.\$i3.1"; fi


echo ""
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}       COPY THIS TO MIKROTIK TERMINAL         ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo ""
echo "# 1. Remove old tunnels"
echo "/interface ipip remove [find name=\"ipip-linux\"]"
echo "/interface gre remove [find name=\"gre-linux\"]"
echo ""
echo "# 2. Create new IPIP Interface"
echo "/interface ipip add name=\"ipip-linux\" local-address=$REMOTE_IP remote-address=$LOCAL_IP mtu=1400"
echo ""
echo "# 3. Add IP Address"
echo "/ip address add address=$MIKROTIK_TUN_IP/30 interface=\"ipip-linux\""
echo ""
echo "# 4. Test Connectivity"
echo "/ping $IP_ADDR count=4"
echo -e "${GREEN}==============================================${NC}"
echo -e "${YELLOW}Setup Complete!${NC}"