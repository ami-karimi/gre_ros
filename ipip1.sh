#!/bin/bash

# --- Color Codes ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=== IPIP Tunnel Setup (Custom Port Routing) ===${NC}"

# --- 1. Network Configuration ---
# Remove old config to force re-entry
rm /etc/tunnel_config.env 2>/dev/null

# Detect Local IP
DEFAULT_LOCAL_IP=$(ip route get 1 | awk '{print $7;exit}')
read -p "Enter Local Server Public IP [$DEFAULT_LOCAL_IP]: " LOCAL_IP
LOCAL_IP=${LOCAL_IP:-$DEFAULT_LOCAL_IP}

while [[ -z "$REMOTE_IP" ]]; do
    read -p "Enter Remote MikroTik Public IP: " REMOTE_IP
done

# --- 2. Direct Ports Input (Crucial Step) ---
echo -e "${YELLOW}--------------------------------------------------${NC}"
echo -e "${YELLOW}DEFINE DIRECT PORTS (Bypass Tunnel)${NC}"
echo "Enter ports that must remain on the Local Server (SSH, X-UI Panel, etc.)"
echo "Format: Comma separated (e.g., 22,2053,54321)"
read -p "Direct Ports [22]: " DIRECT_PORTS
DIRECT_PORTS=${DIRECT_PORTS:-22}
echo -e "${YELLOW}--------------------------------------------------${NC}"

# --- 3. Internal Tunnel IPs ---
TUNNEL_LOCAL="172.16.1.1"
TUNNEL_REMOTE="172.16.1.2"

# --- Start Execution ---
echo -e "${GREEN}[1/4] Cleaning up old network rules...${NC}"

# Remove old interfaces
ip link set ipip1 down 2>/dev/null
ip tunnel del ipip1 2>/dev/null
ip link set tun1 down 2>/dev/null
ip tunnel del tun1 2>/dev/null

# Flush Firewall & Routing
iptables -t mangle -F OUTPUT
iptables -t nat -F POSTROUTING
ip rule del fwmark 100 table 100 2>/dev/null
ip route flush table 100 2>/dev/null

echo -e "${GREEN}[2/4] Creating IPIP Tunnel...${NC}"

# Enable Forwarding
sysctl -w net.ipv4.ip_forward=1 > /dev/null

# Create Tunnel Interface
ip tunnel add ipip1 mode ipip local $LOCAL_IP remote $REMOTE_IP ttl 255
ip link set ipip1 mtu 1400 up
ip addr add $TUNNEL_LOCAL/30 dev ipip1

# Create Custom Routing Table (Table 100)
# Default route for Table 100 is the Tunnel
ip route add default via $TUNNEL_REMOTE dev ipip1 table 100
# Activate the rule: "Traffic marked with 100 goes to Table 100"
ip rule add fwmark 100 table 100

echo -e "${GREEN}[3/4] Configuring Firewall & Port Exclusion...${NC}"

# --- A) EXCLUDE DIRECT PORTS (Do NOT Mark) ---
# These ports will use the default system gateway (Direct Internet)
IFS=',' read -ra PORT_LIST <<< "$DIRECT_PORTS"
for PORT in "${PORT_LIST[@]}"; do
    # Trim whitespace
    PORT=$(echo $PORT | xargs)
    if [[ ! -z "$PORT" ]]; then
        echo " > Excluding Port: $PORT (Direct Connection)"
        # Rule for TCP
        iptables -t mangle -A OUTPUT -p tcp --sport $PORT -j RETURN
        # Rule for UDP
        iptables -t mangle -A OUTPUT -p udp --sport $PORT -j RETURN
    fi
done

# --- B) ANTI-LOOP MECHANISMS (Critical) ---
# 1. Do not mark IPIP protocol traffic (Proto 4)
iptables -t mangle -A OUTPUT -p 4 -j RETURN
# 2. Do not mark traffic destined for MikroTik Public IP
iptables -t mangle -A OUTPUT -d $REMOTE_IP -j RETURN
# 3. Do not mark ICMP (Ping) - Optional, useful for debugging
iptables -t mangle -A OUTPUT -p icmp -j RETURN

# --- C) MARK EVERYTHING ELSE (User Traffic) ---
# Any traffic NOT matched above gets marked with 100
iptables -t mangle -A OUTPUT -j MARK --set-mark 100

# --- D) Optimization & NAT ---
# Clamp MSS to prevent packet fragmentation issues
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o ipip1 -j TCPMSS --clamp-mss-to-pmtu
# Masquerade traffic leaving the tunnel
iptables -t nat -A POSTROUTING -o ipip1 -j MASQUERADE

echo ""
echo -e "${GREEN}=== Setup Complete Successfully ===${NC}"
echo "--------------------------------------------------"
echo -e "Direct Ports (Local Internet): ${YELLOW}$DIRECT_PORTS${NC}"
echo -e "Tunnel Ports (MikroTik):       ${BLUE}ALL OTHER PORTS${NC}"
echo "--------------------------------------------------"

echo ""
echo -e "${GREEN}=== MIKROTIK COMMANDS (Copy & Paste) ===${NC}"
echo "/interface ipip remove [find name=\"ipip-linux\"]"
echo "/interface ipip add name=\"ipip-linux\" local-address=$REMOTE_IP remote-address=$LOCAL_IP mtu=1400"
echo "/ip address add address=$TUNNEL_REMOTE/30 interface=\"ipip-linux\""
echo "/ip firewall nat add chain=srcnat src-address=172.16.1.0/30 action=masquerade"
echo ""