#!/bin/bash

# Configuration
HOME_GATEWAY="192.168.1.1"
HOME_SUBNET="192.168.1"

echo "=== Network Check ==="

# Check if we're on the home network
CURRENT_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+')

if [[ -z "$CURRENT_IP" ]]; then
  echo "  ⚠ No network connection detected - exiting"
  exit 0
fi

if [[ "$CURRENT_IP" =~ ^$HOME_SUBNET\. ]] && ping -c 1 -W 1 "$HOME_GATEWAY" > /dev/null 2>&1; then
  echo "  ✓ Home network detected ($CURRENT_IP)"
else
  echo "  ⚠ Not on home network (Current IP: $CURRENT_IP)"
  echo "  Skipping updates to prevent incorrect entries"
  exit 0
fi

echo ""
echo "=== SSH Server Setup ==="

# Check if OpenSSH server is already installed
if dpkg -l | grep -q "^ii.*openssh-server"; then
  echo "  ✓ OpenSSH server is already installed"
else
  echo "  Installing OpenSSH server..."
  sudo apt update
  sudo apt install -y openssh-server
  echo "  ✓ OpenSSH server installed"
fi

# Ensure SSH service is enabled and started
if systemctl is-active --quiet ssh; then
  echo "  ✓ SSH service is running"
else
  echo "  Starting SSH service..."
  sudo systemctl start ssh
  sudo systemctl enable ssh
  echo "  ✓ SSH service started and enabled"
fi

echo ""
echo "=== Network Host Discovery ==="

# Backup /etc/hosts before making changes (only once)
BACKUP_FILE="/etc/hosts.backup"
if [[ ! -f "$BACKUP_FILE" ]]; then
  sudo cp /etc/hosts "$BACKUP_FILE"
  echo "  ✓ Created backup: $BACKUP_FILE"
fi

# Remove old auto-generated section if it exists
sudo sed -i '/# BEGIN AUTO-GENERATED HOSTS/,/# END AUTO-GENERATED HOSTS/d' /etc/hosts

# Display ARP cache and store output in variable
arp_cache=$(arp -a)

# Use associative array to track unique hostname+IP combinations (ignore interface)
declare -A seen_entries

echo "Scanning network and updating /etc/hosts..."

# Start auto-generated section
echo "# BEGIN AUTO-GENERATED HOSTS - DO NOT EDIT MANUALLY" | sudo tee -a /etc/hosts > /dev/null

# Parse output of arp -a, extract relevant information
IFS=$'\n' GLOBIGNORED='*' readarray -t devices <<< "$arp_cache"
for device in "${devices[@]}"; do
  ip=$(echo "$device" | awk '{print $2}' | tr -d '()')
  hostname=$(echo "$device" | awk '{print $1}')
  mac=$(echo "$device" | awk '{print $4}')
  interface=$(echo "$device" | awk '{print $NF}')
  
  # Skip Docker bridge interfaces
  if [[ "$interface" =~ ^br- ]]; then
    continue
  fi
  
  # Only process IPs from home subnet
  if [[ ! "$ip" =~ ^$HOME_SUBNET\. ]]; then
    continue
  fi
  
  # Skip if hostname is empty, is "?", or MAC is incomplete
  if [[ ! -z "$hostname" && "$hostname" != "?" && "$mac" != "<incomplete>" ]]; then
    # Remove .home.local suffix (or any .local suffix)
    short_hostname=$(echo "$hostname" | sed 's/\.home\.local$//' | sed 's/\.local$//')
    
    # Create unique key from IP only (since same device appears on multiple interfaces)
    entry_key="${ip}"
    
    # Skip if we've already processed this IP
    if [[ -n "${seen_entries[$entry_key]}" ]]; then
      continue
    fi
    
    # Mark as seen
    seen_entries[$entry_key]="${short_hostname}"
    
    # Add to /etc/hosts
    echo "${ip} ${short_hostname}" | sudo tee -a /etc/hosts > /dev/null
    echo "  ✓ Added: ${ip} ${short_hostname}"
  fi
done

# End auto-generated section
echo "# END AUTO-GENERATED HOSTS" | sudo tee -a /etc/hosts > /dev/null

echo -e "\nDone updating /etc/hosts"

# Display SSH status
echo ""
echo "=== SSH Server Status ==="
echo "  IP Addresses:"
hostname -I | tr ' ' '\n' | grep -v '^$' | sed 's/^/    /'
echo ""
echo "  Connect with: ssh $(whoami)@<ip-address>"

echo ""
echo "=== Automatic Updates Setup ==="

# Get the absolute path of this script
SCRIPT_PATH="$(readlink -f "$0")"

# Check if cron entry already exists for this specific script
if crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH" > /dev/null; then
  echo "  ✓ Cron job already exists"
else
  echo "  Creating cron job to run every 10 minutes..."
  # Add to user's crontab (runs every 10 minutes)
  (crontab -l 2>/dev/null; echo "*/10 * * * * $SCRIPT_PATH >> /tmp/update-hosts.log 2>&1") | crontab -
  echo "  ✓ Cron job created - runs every 10 minutes"
fi

echo ""
echo "  Management commands:"
echo "    View cron jobs:      crontab -l"
echo "    Edit cron jobs:      crontab -e"
echo "    View logs:           tail -f /tmp/update-hosts.log"
echo "    Remove cron job:     crontab -e (then delete the line)"
echo "    Restore hosts file:  sudo cp /etc/hosts.backup /etc/hosts"