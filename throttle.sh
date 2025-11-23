
IFACE_HOTSPOT="ap0"
TC_ROOT_ID="1:"
TC_CLIENT_CLASS="1:1"
UPLOAD_CHAIN="UPLOAD_LIMIT"

set -u

get_host_ip() {
    ip a show $IFACE_HOTSPOT 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d '/' -f 1 | head -n 1
}

calculate_rate() {
    local speed_value=$1
    local speed_unit=$2
    case "$speed_unit" in
        "MB/s")
            tc_rate=$(awk "BEGIN {printf \"%d\", ($speed_value * 8)}")
            echo "${tc_rate}mbit"
            ;;
        "KB/s")
            tc_rate=$(awk "BEGIN {printf \"%d\", ($speed_value * 8)}")
            echo "${tc_rate}kbit"
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

calculate_hashlimit() {
    local speed_value=$1
    local speed_unit=$2
    case "$speed_unit" in
        "MB/s")
            limit=$(awk "BEGIN {printf \"%d\", ($speed_value * 1024)}")
            echo "${limit}kb/s"
            ;;
        "KB/s")
            echo "${speed_value}kb/s"
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

show_status() {
    echo ""
    echo "--- Current Limit Status ---"

    DL_QDISC=$(tc qdisc show dev $IFACE_HOTSPOT 2>/dev/null | grep "htb 1: root" || true)
    if [ -z "$DL_QDISC" ]; then
        echo "Download shaping: NOT APPLIED"
    else
        RATE_LIMIT=$(tc class show dev $IFACE_HOTSPOT | grep "$TC_CLIENT_CLASS" | awk '{for(i=1;i<=NF;i++) if($i == "rate") print $(i+1)}' | head -n1)
        echo "Download shaping: APPLIED ($RATE_LIMIT)"
        echo ""
        echo "Download statistics:"
        tc -s class show dev $IFACE_HOTSPOT 2>/dev/null | grep -A3 "class htb 1:1"
    fi

    echo ""
    if iptables -L $UPLOAD_CHAIN -n 2>/dev/null | grep -qi "limit:\|DROP"; then
        echo "Upload shaping: APPLIED (iptables hashlimit)"
        echo ""
        echo "Upload statistics:"
        iptables -L $UPLOAD_CHAIN -n -v 2>/dev/null
        echo ""
        echo "Packets dropped (exceeded rate limit):"
        iptables -L $UPLOAD_CHAIN -n -v 2>/dev/null | grep DROP | awk '{print "  " $1 " packets (" $2 " bytes)"}'
    else
        echo "Upload shaping: NOT APPLIED"
    fi

    echo ""
    echo "----------------------------------------"
    echo "Method: HTB for download + iptables hashlimit for upload"
    echo "----------------------------------------"
}

remove_limit() {
    quiet=false
    if [ "${1:-}" = "quiet" ]; then
        quiet=true
    fi

    if [ "$quiet" = "false" ]; then
        echo "Removing all traffic control and firewall rules..."
    fi

    tc qdisc del dev $IFACE_HOTSPOT root 2>/dev/null || true
    tc qdisc del dev $IFACE_HOTSPOT clsact 2>/dev/null || true


    iptables -D FORWARD -i $IFACE_HOTSPOT -j $UPLOAD_CHAIN 2>/dev/null || true
    iptables -F $UPLOAD_CHAIN 2>/dev/null || true
    iptables -X $UPLOAD_CHAIN 2>/dev/null || true

    if [ "$quiet" = "false" ]; then
        echo "Limits Removed."
        sleep 1
    fi
}


apply_limit() {
    HOST_IP=$(get_host_ip)
    if [ -z "$HOST_IP" ]; then
        echo "Error: Could not determine Host IP on $IFACE_HOTSPOT. Is the hotspot active?"
        return 1
    fi
    echo "Host IP detected: $HOST_IP"

    echo ""
    echo "Enter the desired speed VALUE (e.g., 10 or 0.5): "
    read speed_value
    if [ -z "$speed_value" ]; then
        echo "Error: Speed value cannot be empty."
        return 1
    fi

    echo ""
    echo "Enter the unit (K for KB/s, M for MB/s): "
    read speed_unit_input

    speed_unit_norm=$(echo "$speed_unit_input" | tr '[:lower:]' '[:upper:]')
    case "$speed_unit_norm" in
        K) unit_clean="KB/s" ;;
        M) unit_clean="MB/s" ;;
        *) echo "Error: Invalid unit. Use K or M." ; return 1 ;;
    esac

    TC_RATE=$(calculate_rate "$speed_value" "$unit_clean")
    HASHLIMIT=$(calculate_hashlimit "$speed_value" "$unit_clean")
    
    if [ -z "$TC_RATE" ] || [ -z "$HASHLIMIT" ]; then
        echo "Error calculating rates."
        return 1
    fi

    echo ""
    echo "--- Applying $speed_value $unit_clean ---"
    echo "Download: $TC_RATE (HTB)"
    echo "Upload: $HASHLIMIT (iptables hashlimit)"


    remove_limit quiet

    echo ""
    echo "Scanning connected IPs on $IFACE_HOTSPOT..."
    CONNECTED_IPS=$(cat /proc/net/arp 2>/dev/null | grep $IFACE_HOTSPOT | awk "\$1 != \"$HOST_IP\" {print \$1}" | sort | uniq)
    if [ -z "$CONNECTED_IPS" ]; then
        echo "Note: No clients currently connected."
    else
        echo "Found connected clients:"
        for IP in $CONNECTED_IPS; do
            [ -z "$IP" ] && continue
            echo "  - $IP"
        done
    fi

    echo ""
    echo "Applying download limit (egress HTB)..."
    tc qdisc del dev $IFACE_HOTSPOT root 2>/dev/null || true
    tc qdisc add dev $IFACE_HOTSPOT root handle ${TC_ROOT_ID} htb default 1
    tc class add dev $IFACE_HOTSPOT parent ${TC_ROOT_ID} classid ${TC_CLIENT_CLASS} htb rate ${TC_RATE} ceil ${TC_RATE} 2>/dev/null || true
    echo "  ✓ Download shaping applied: $TC_RATE"


    echo ""
    echo "Applying upload limit (iptables hashlimit)..."
    
    iptables -N $UPLOAD_CHAIN 2>/dev/null || true
    iptables -F $UPLOAD_CHAIN 2>/dev/null || true
    
    BURST_KB=$(awk "BEGIN {printf \"%d\", ($speed_value * 1)}")
    case "$speed_unit_norm" in
        M) BURST_KB=$(awk "BEGIN {printf \"%d\", ($speed_value * 1024 * 1)}") ;;
    esac
    [ $BURST_KB -lt 50 ] && BURST_KB=50

    iptables -A $UPLOAD_CHAIN -m hashlimit \
        --hashlimit-above ${HASHLIMIT} \
        --hashlimit-burst ${BURST_KB}kb \
        --hashlimit-mode srcip \
        --hashlimit-name upload_limit \
        --hashlimit-htable-expire 10000 \
        -j DROP 2>/dev/null
    
    RESULT=$?
    
    if [ $RESULT -eq 0 ]; then
        iptables -I FORWARD -i $IFACE_HOTSPOT -j $UPLOAD_CHAIN 2>/dev/null
        echo "  ✓ Upload shaping applied: $HASHLIMIT (burst: ${BURST_KB}kb)"
        echo ""
        echo "  Verifying iptables rules..."
        if iptables -L FORWARD -n | grep -q $UPLOAD_CHAIN; then
            echo "  ✓ FORWARD chain configured correctly"
        else
            echo "  ✗ WARNING: Jump rule not found in FORWARD chain"
        fi
        if iptables -L $UPLOAD_CHAIN -n | grep -qi "limit:\|DROP"; then
            echo "  ✓ Upload limit rule active"
        else
            echo "  ✗ WARNING: Hashlimit rule not found"
        fi
    else
        echo "  ✗ ERROR: Failed to apply upload shaping (exit code: $RESULT)"
        echo "    Your device may not support hashlimit module"
        echo "    Download shaping will still work"
    fi

    echo ""
    echo "=========================================="
    echo "Configuration Complete!"
    echo "=========================================="
    echo "Speed limit: $speed_value $unit_clean"
    echo "  Download (egress): $TC_RATE"
    echo "  Upload (ingress): $HASHLIMIT"
    echo ""
    echo "Test both directions from a connected device."
    echo ""
    echo "To view statistics, run: sh throttle.sh"
    echo "Then choose (S)tatus"
    echo "=========================================="
    
    return 0
}

if [ "$(whoami)" != "root" ]; then
    echo "Error: Please run this script using 'sh throttle.sh' after running 'su'."
    exit 1
fi

echo "--- Hotspot Bandwidth Throttling Script ---"
echo "Do you want to (A)pply, (R)emove, or view (S)tatus? (A/R/S): "
read action
action=$(echo "$action" | tr '[:lower:]' '[:upper:]')

case "$action" in
    A) apply_limit ;;
    R) remove_limit ;;
    S) show_status ;;
    *) echo "Invalid choice. Exiting." ;;
esac

exit 0