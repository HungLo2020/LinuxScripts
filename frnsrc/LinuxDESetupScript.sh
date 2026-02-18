#!/bin/bash


wifi_drivers=false
nvidia_drivers=false
rclone_resync=false
teamviewer=false
snaps=false
appimages=false
workstation=false

## Asks questions for setup
while true; do
    read -p "Do you want to install Broadcom Wifi drivers? (y/n): " choice
    case "$choice" in
        [Yy]* )
            wifi_drivers=true
            break
            ;;
        [Nn]* )
            wifi_drivers=false
            break
            ;;
        "" )
            wifi_drivers=false
            break
            ;;
        * )
            echo "Please answer y or n."
            ;;
    esac
done

while true; do
    read -p "Do you want to install Snap Packages (Firefox & Thunderbird)? (y/n): " choice
    case "$choice" in
        [Yy]* )
            snaps=true
            break
            ;;
        [Nn]* )
            snaps=false
            break
            ;;
        "" )
            snaps=false
            break
            ;;
        * )
            echo "Please answer y or n."
            ;;
    esac
done

while true; do
    read -p "Do you want to install AppImage packages? (y/n): " choice
    case "$choice" in
        [Yy]* )
            appimages=true
            break
            ;;
        [Nn]* )
            appimages=false
            break
            ;;
        "" )
            appimages=false
            break
            ;;
        * )
            echo "Please answer y or n."
            ;;
    esac
done



while true; do
    read -p "Do you want to install Nvidia Drivers? (y/n): " choice
    case "$choice" in
        [Yy]* )
            nvidia_drivers=true
            break
            ;;
        [Nn]* )
            nvidia_drivers=false
            break
            ;;
        "" )
            nvidia_drivers=false
            break
            ;;
        * )
            echo "Please answer y or n."
            ;;
    esac
done

while true; do
    read -p "Do you want to run rclone resync? (y/n): " choice
    case "$choice" in
        [Yy]* )
            rclone_resync=true
            break
            ;;
        [Nn]* )
            rclone_resync=false
            break
            ;;
        "" )
            rclone_resync=false
            break
            ;;
        * )
            echo "Please answer y or n."
            ;;
    esac
done

sudo apt-get update -y
sudo apt upgrade -yq
sudo add-apt-repository multiverse -y

## Resize swap
sudo swapoff -a
sudo dd if=/dev/zero of=/swapfile bs=1G count=16
sudo mkswap /swapfile
sudo swapon /swapfile

# Wifi Drivers
if $wifi_drivers; then
    sudo apt-get install broadcom-sta-dkms
else
    echo "skipping broadcom wifi drivers"
fi

# Nvidia Drivers
if $nvidia_drivers; then
    sudo ubuntu-drivers install nvidia:560
else
    echo "skipping nvidia drivers"
fi


# Installing APT Programs
programs=("steam" "cool-retro-term" "rclone" "virt-manager" "variety" "libreoffice" "qdirstat" "baobab" "partitionmanager" "mintstick" "python3-pip" "pipx" "flatpak" "retroarch" "kate" "konsole" "dolphin" "kmines" "neofetch" "freecad")
for prog in "${programs[@]}"; do
  sudo apt install -y "$prog"
  echo "Installed $prog"
done

# Installing Flatpaks
sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
fprograms=("flathub" "bottles" "flatseal" "MissionCenter")
for prog in "${fprograms[@]}"; do
  sudo flatpak install -y "$prog"
  echo "Installed $prog"
done

#Installs AppImageLauncher
if $appimages; then
	wget -P /home/matt/Downloads/	Appimagelauncher "https://github.com/TheAssassin/AppImageLauncher/releases/download/v2.2.0/appimagelauncher_2.2.0-travis995.0f91801.bionic_amd64.deb"
	cd /home/matt/Downloads/Appimagelauncher/
	sudo dpkg -i *.deb
else
    echo "skipping AppImage Launcher"
fi


# Install Thunderbird without Snap
if $snaps; then
	sudo tee /etc/apt/preferences.d/thunderbird-no-snap > /dev/null <<EOF
Package: thunderbird*
Pin: release o=Ubuntu*
Pin-Priority: -1
EOF

	sudo snap remove thunderbird -y
	sudo add-apt-repository ppa:mozillateam/ppa -y
	sudo apt update
	sudo apt install thunderbird -y
	echo "Installed Thunderbird (non-Snap)"

# Install Firefox without Snap
	sudo tee /etc/apt/preferences.d/firefox-no-snap > /dev/null <<EOF
Package: firefox*
Pin: release o=Ubuntu*
Pin-Priority: -1
EOF

	sudo apt purge firefox -y
	sudo snap remove firefox -y
	sudo add-apt-repository ppa:mozillateam/ppa -y
	sudo apt update
	sudo apt install firefox -y
	echo 'Unattended-Upgrade::Allowed-Origins:: "LP-PPA-mozillateam:${distro_codename}";' | sudo tee /etc/apt/apt.conf.d/51unattended-upgrades-firefox
else
    echo "skipping Firefox and Thunderbird Snaps"
fi


#Installs Steam
#steam

#Installs Discord
wget -P /home/matt/Downloads/Discord "https://discord.com/api/download?platform=linux&format=deb"
cd /home/matt/Downloads/Discord/
sudo dpkg -i *.deb
sudo dpkg -i *=deb

#explains how to set up Rclone for onedrive and sets up automount
# Path to the rclone config file
RCLONE_CONFIG="/home/matt/.config/rclone/rclone.conf"
ONEDRIVE_DIR="/home/matt/OneDrive"
# Check if the rclone config file exists
if [[ -f "$RCLONE_CONFIG" ]]; then
  echo "Rclone config file exists. Skipping OneDrive setup."
else
  echo ""
  echo "Starting interactive rclone setup for OneDrive..."
  echo "When you finish, exit the rclone config menu (q)."
  echo ""

  # Force rclone to use the real terminal for input/output so it won't "skip ahead"
  # even if the script is run with redirected stdin/stdout.
  while true; do
    rclone config --config "$RCLONE_CONFIG" </dev/tty >/dev/tty 2>&1
    # Verify the remote we need actually exists before continuing
    if rclone listremotes --config "$RCLONE_CONFIG" 2>/dev/null | grep -qE '^OneDrive:$'; then
      echo "Found remote 'OneDrive:' in $RCLONE_CONFIG"
      break
    fi
    echo ""
    echo "It doesn't look like a remote named 'OneDrive' was created yet."
    echo "Press Enter to run 'rclone config' again, or Ctrl+C to abort."
    read -r </dev/tty
  done

  # Create OneDrive mount directory
  mkdir -p "$ONEDRIVE_DIR"
  sudo chown matt:matt "$ONEDRIVE_DIR"
  # Set up systemd service for automatic mounting
  echo "Creating systemd service for Rclone OneDrive auto-mount..."
  sudo tee /etc/systemd/system/rclone-mount.service > /dev/null <<EOF
[Unit]
Description=Rclone mount for OneDrive
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/rclone mount OneDrive: $ONEDRIVE_DIR --vfs-cache-mode writes
ExecStop=/bin/fusermount -uz $ONEDRIVE_DIR
Restart=on-failure
User=matt
Group=matt

[Install]
WantedBy=default.target
EOF
  # Reload systemd and enable the service
  sudo systemctl daemon-reload
  sudo systemctl enable rclone-mount.service
  sudo systemctl start rclone-mount.service

  # Final permissions for OneDrive directory
  sudo -u matt chmod 777 "$ONEDRIVE_DIR"
  echo "OneDrive setup and auto-mount configuration complete."
fi

#Make missing dirs for cron
mkdir -p /home/matt/OneDrive-Local/Media/Wallpapers/

#Setup Crontab based on file
sudo -u matt cp "/home/matt/OneDrive/Documents/Scripts/LinuxDESetupScriptStuff/newcrontab.txt" /home/matt/Downloads/
crontab /home/matt/Downloads/newcrontab.txt
sudo service cron reload
sudo rm /home/matt/Downloads/newcrontab.txt

#Inital rclone syncs
if $rclone_resync; then
    rclone bisync /home/matt/OneDrive/Media/Wallpapers/ /home/matt/OneDrive-Local/Media/Wallpapers/ --resync --verbose &
else
    echo "skipping"
fi

#Install Teamviewer
if $teamviewer; then
    sudo apt update
    sudo apt install -y wget gnupg2 software-properties-common
    wget https://download.teamviewer.com/download/linux/teamviewer_amd64.deb -O /tmp/teamviewer.deb
    sudo dpkg -i /tmp/teamviewer.deb
    sudo apt install -f -y
    rm /tmp/teamviewer.deb
    sudo systemctl enable teamviewerd
    sudo systemctl start teamviewerd
    teamviewer --version
else
    echo "You chose no. Variable is set to false."
fi

#Install Konsave and import KDE settings
sudo -u matt cp "/home/matt/OneDrive/Documents/Scripts/LinuxDESetupScriptStuff/HungLoKDENormal.knsv" /home/matt/Downloads/
python3 -m venv konsave-env
source konsave-env/bin/activate
pip install setuptools konsave
konsave -r HungLoKDENormal
konsave -i /home/matt/Downloads/HungLoKDENormal.knsv
konsave -a HungLoKDENormal
deactivate
rm /home/matt/Downloads/HungLoKDENormal.knsv

# Install Cura and Godot
if $workstation; then
    sudo -u matt cp -r "/home/matt/OneDrive/Apps/Programs/Cura/" /home/matt/Downloads/
    cd /home/matt/Downloads/Cura/
    sudo chmod +x *.AppImage
    sudo ./*.AppImage
    cd /home/matt/Downloads/
    sudo -u matt cp -r "/home/matt/OneDrive/Apps/Programs/Godot/Godot_v4.3-stable_linux.x86_64" /home/matt/Downloads/
    sudo chmod +x *.x86_64
    sudo ./*x86_64
    sudo rm Cura/ -r
    sudo cp ./*x86_64 /home/matt/Applications/
    sudo rm ./*x86_64
else
    echo "Skipping Workstation stuff (Cura, Godot)."
fi

#Final Variety Config
sudo -u matt cp "/home/matt/OneDrive/Documents/Scripts/LinuxDESetupScriptStuff/variety.conf" /home/matt/.config/variety/variety.conf
variety &

#Cleanup
# Removing APT Programs
rprograms=("plasma-vault" "krdc" "neochat" "konversation" "skanlite" "akregator" "dragonplayer" "gimp" "juk" "kdeconnect" "kmail" "kmouth" "konqueror" "knotes" "korganizer" "kwrite")
for prog in "${rprograms[@]}"; do
  sudo apt remove -y "$prog"
  echo "Uninstalled $prog"
done
sudo apt autoremove -y

sudo rm -r /home/matt/Downloads/{GDLauncher,Discord,Appimagelauncher}
echo "Cleanup Complete, Please reboot your computer"

