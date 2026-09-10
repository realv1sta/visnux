#!/bin/bash

set -u
set -o pipefail

LOG_FILE="/tmp/visnux_install.log"
> "$LOG_FILE"

cleanup() {
    clear
}
trap cleanup EXIT

dialog --title "Visnux Linux" --msgbox "Welcome to Visnux Linux! Before running the installer, partition your drives. Because we do NOT make your drives, do em yourself\n\n With love,\n v1sta_" 0 0; clear

check_mount() {
    if ! mountpoint -q /mnt; then
        dialog --title "BRO" --msgbox "Mount your drives BETTER noob. I see no /mnt >:(" 0 0; clear
        return 1
    fi
    return 0
}

refresh_mirrors() {
    pacman -Sy --noconfirm reflector curl >> "$LOG_FILE" 2>&1 || return 1

    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

    LOCATION=$(curl -s --max-time 5 https://ipinfo.io/country | tr -d '[:space:]')

    REFLECTOR_OK=true
    if [ -n "$LOCATION" ]; then
        reflector --country "$LOCATION" --latest 10 --protocol https --sort rate --download-timeout 5 --save /etc/pacman.d/mirrorlist >> "$LOG_FILE" 2>&1 || REFLECTOR_OK=false
    else
        REFLECTOR_OK=false
    fi

    if [ "$REFLECTOR_OK" = false ] || [ ! -s /etc/pacman.d/mirrorlist ]; then
        reflector --latest 10 --protocol https --sort rate --download-timeout 5 --save /etc/pacman.d/mirrorlist >> "$LOG_FILE" 2>&1
    fi

    if [ ! -s /etc/pacman.d/mirrorlist ]; then
        cp /etc/pacman.d/mirrorlist.backup /etc/pacman.d/mirrorlist
    fi

    pacman -Syy --noconfirm archlinux-keyring >> "$LOG_FILE" 2>&1
}

NEW_HOSTNAME=""
INIT_SYSTEM=""
DESKTOP_ENV=""
ENABLE_MULTILIB="yes"
BOOT_MODE="bios"
GRUB_DISK=""

if [ -d /sys/firmware/efi/efivars ]; then
    BOOT_MODE="uefi"
fi

while true; do
    MENU=$(dialog --title "Installation Menu" --menu "Choose an option" 15 50 5 \
        1 "Hostname" \
        2 "Init Selection" \
        3 "DE selection" \
        4 "Enable Multilib (32-bit)" \
        5 "Install" 3>&1 1>&2 2>&3 3>&-)

    STATUS=$?
    clear

    if [ "$STATUS" -ne 0 ]; then
        echo "You stopped the Installation Process"
        break
    fi

    if [ "$MENU" == "1" ]; then
        while true; do
            NEW_HOSTNAME=$(dialog --title "Hostname" --inputbox "Create your hostname: " 0 0 3>&1 1>&2 2>&3 3>&-); clear
            if [ -z "$NEW_HOSTNAME" ]; then
                dialog --title "Uh oh.." --msgbox "You can't leave the hostname blank, try again" 0 0; clear
                continue
            fi
            break
        done
        dialog --title "Success!" --msgbox "Your host name will be: $NEW_HOSTNAME." 0 0; clear
    fi

    if [ "$MENU" == "2" ]; then
        INIT_CHOICE=$(dialog --title "Init Selection" --menu "Choose your prefered init: " 12 40 4 \
            "systemd" "systemd" \
            "openrc" "openrc" \
            "runit" "runit" \
            "dinit" "dinit" 3>&1 1>&2 2>&3 3>&-); clear

        if [ -n "$INIT_CHOICE" ]; then
            INIT_SYSTEM="$INIT_CHOICE"
            dialog --title "Mirrors" --infobox "Finding fast mirrors for your location, hang on..." 0 0
            if refresh_mirrors; then
                dialog --title "Mirrors" --msgbox "Mirrors updated!" 0 0; clear
            else
                dialog --title "Uh oh.." --msgbox "Mirror refresh failed, using default mirrorlist." 0 0; clear
            fi
        fi
    fi

    if [ "$MENU" == "3" ]; then
        DE_CHOICE=$(dialog --title "DE Selection" --menu "Choose your prefered DE: " 12 40 3 \
            "kde" "KDE Plasma" \
            "xfce" "XFCE4" \
            "none" "No DE (CLI only)" 3>&1 1>&2 2>&3 3>&-); clear

        if [ -n "$DE_CHOICE" ]; then
            DESKTOP_ENV="$DE_CHOICE"
        fi
    fi

    if [ "$MENU" == "4" ]; then
        dialog --title "Multilib" --yesno "Enable 32-bit (multilib) repository support?" 0 0
        if [ $? -eq 0 ]; then
            ENABLE_MULTILIB="yes"
        else
            ENABLE_MULTILIB="no"
        fi
        clear
    fi

    if [ "$MENU" == "5" ]; then

        MISSING=""
        [ -z "${NEW_HOSTNAME:-}" ] && MISSING="${MISSING}\n - Hostname"
        [ -z "${INIT_SYSTEM:-}" ] && MISSING="${MISSING}\n - Init Selection"
        [ -z "${DESKTOP_ENV:-}" ] && MISSING="${MISSING}\n - DE selection"

        if [ -n "$MISSING" ]; then
            dialog --title "Hold up!" --msgbox "You still need to finish these before installing:$MISSING" 0 0; clear
            continue
        fi

        if ! check_mount; then
            continue
        fi

        dialog --title "Warning!" --yesno "If you click confirm, Visnux Linux will install on your disk/partition. THIS ACTION CANT BE REVERSED! Soo do it at ur own risk <3" 0 0

        STATUS=$?
        clear

        if [ "$STATUS" -ne 0 ]; then
            echo "You stopped the Installation Process"
            break
        else
            MNT_DEV=$(findmnt -n -o SOURCE /mnt)
            GRUB_DISK=$(lsblk -no PKNAME "$MNT_DEV" | head -n1)
            [ -n "$GRUB_DISK" ] && GRUB_DISK="/dev/$GRUB_DISK" || GRUB_DISK="/dev/sda"

            dialog --title "Installing..." --infobox "Installation in progress. Logs are written to $LOG_FILE..." 0 0

            if [ "$INIT_SYSTEM" = "systemd" ]; then
                command -v pacstrap &>/dev/null || { echo "'pacstrap' not found."; exit 1; }

                sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /etc/pacman.conf

                pacman -Sy archlinux-keyring --noconfirm >> "$LOG_FILE" 2>&1
                pacstrap /mnt base base-devel linux linux-firmware sof-firmware >> "$LOG_FILE" 2>&1

                sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /mnt/etc/pacman.conf
                sed -i '/^ParallelDownloads = 12/a Color\nILoveCandy' /mnt/etc/pacman.conf

                if grep -q '^\[multilib\]$' /mnt/etc/pacman.conf; then
                    sed -i '/^\[multilib\]/,/^\[/ s#^Include = /etc/pacman.d/mirrorlist$#Include = /etc/pacman.d/mirrorlist#' /mnt/etc/pacman.conf
                elif [ "$ENABLE_MULTILIB" = "yes" ]; then
                    cat >> /mnt/etc/pacman.conf <<'EOF'

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
                fi
            else
                ARTIX_BOOTSTRAP_CONF="/tmp/visnux-artix-bootstrap.conf"
                cat > "$ARTIX_BOOTSTRAP_CONF" <<EOF
[options]
Architecture = auto
Color
CheckSpace
ParallelDownloads = 12
SigLevel = Never

[system]
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch
EOF

                pacman --config "$ARTIX_BOOTSTRAP_CONF" -Sy --noconfirm artix-keyring >> "$LOG_FILE" 2>&1
                pacman-key --init >> "$LOG_FILE" 2>&1
                pacman-key --populate artix >> "$LOG_FILE" 2>&1

                ARTIX_CONF="/tmp/visnux-artix.conf"
                cat > "$ARTIX_CONF" <<EOF
[options]
Architecture = auto
Color
CheckSpace
ParallelDownloads = 12
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

[system]
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch
[world]
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch
[galaxy]
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch
EOF

                command -v pacstrap &>/dev/null || { echo "'pacstrap' not found."; exit 1; }

                INIT_PKGS=""
                case "$INIT_SYSTEM" in
                    openrc) INIT_PKGS="openrc elogind-openrc" ;;
                    runit)  INIT_PKGS="runit runit-rc elogind-runit" ;;
                    dinit)  INIT_PKGS="dinit elogind-dinit" ;;
                esac

                pacstrap -C "$ARTIX_CONF" /mnt base base-devel linux linux-firmware sof-firmware artix-keyring artix-mirrorlist $INIT_PKGS >> "$LOG_FILE" 2>&1

                echo 'Server = https://mirrors.rit.edu/artixlinux/$repo/os/$arch' > /mnt/etc/pacman.d/mirrorlist

                sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /mnt/etc/pacman.conf
                sed -i '/^ParallelDownloads = 12/a Color\nILoveCandy' /mnt/etc/pacman.conf

                arch-chroot /mnt pacman -Sy --noconfirm artix-mirrorlist >> "$LOG_FILE" 2>&1
                arch-chroot /mnt pacman -Sy --noconfirm artix-archlinux-support >> "$LOG_FILE" 2>&1
                arch-chroot /mnt pacman-key --populate archlinux >> "$LOG_FILE" 2>&1

                if [ "$ENABLE_MULTILIB" = "yes" ]; then
                    if ! grep -q '^\[multilib\]$' /mnt/etc/pacman.conf; then
                        cat >> /mnt/etc/pacman.conf <<'EOF'

[multilib]
Include = /etc/pacman.d/mirrorlist-arch
EOF
                    fi
                fi
            fi

            genfstab -U /mnt > /mnt/etc/fstab

            cat > /mnt/root/chroot-install.sh <<CHROOT_EOF
#!/bin/bash
set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "\${GREEN}[CHROOT]\${NC}  \$*"; }
warn()  { echo -e "\${YELLOW}[CHROOT]\${NC}  \$*"; }

BOOT_MODE="${BOOT_MODE}"
INIT_SYSTEM="${INIT_SYSTEM}"
DESKTOP_ENV="${DESKTOP_ENV}"
NEW_HOSTNAME="${NEW_HOSTNAME}"
GRUB_DISK="${GRUB_DISK}"

hwclock --systohc

pacman -Sy --noconfirm git ttf-iosevka-nerd ttf-adwaitamono-nerd fish flatpak papirus-icon-theme
mkdir -p /usr/share/icons/hicolor/scalable/apps/
mkdir -p /usr/share/pixmaps/

echo "\${NEW_HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   \${NEW_HOSTNAME}.localdomain \${NEW_HOSTNAME}
EOF

cat > /etc/os-release <<'EOF'
NAME="Visnux"
PRETTY_NAME="Visnux Linux"
ID=visnux
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;85;255;85"
HOME_URL="https://visnux.duckdns.org/"
DOCUMENTATION_URL="https://visnux.duckdns.org/"
LOGO=visnux
EOF

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

if [ "\${INIT_SYSTEM}" = "systemd" ]; then

    if [ "\${DESKTOP_ENV}" = "kde" ]; then
        pacman -S plasma konsole dolphin wl-clipboard kitty fastfetch sddm networkmanager neovim nano sudo power-profiles-daemon --noconfirm
        systemctl enable NetworkManager
        systemctl enable sddm --force

    elif [ "\${DESKTOP_ENV}" = "xfce" ]; then
        pacman -S xfce4 xfce4-whiskermenu-plugin xclip maim xfce4-pulseaudio-plugin kitty fastfetch sddm networkmanager neovim nano sudo power-profiles-daemon --noconfirm
        systemctl enable NetworkManager
        systemctl enable sddm --force

    else
        info "Skipping Desktop Environment installation."
        pacman -S networkmanager neovim nano sudo --noconfirm
        systemctl enable NetworkManager
    fi

else

    if [ "\${DESKTOP_ENV}" = "kde" ]; then
        DE_PKGS="plasma konsole dolphin"
        DESKTOP_PKGS="kitty fastfetch wl-clipboard sddm sddm-\${INIT_SYSTEM} power-profiles-daemon power-profiles-daemon-\${INIT_SYSTEM} pipewire pipewire-\${INIT_SYSTEM} pipewire-pulse pipewire-pulse-\${INIT_SYSTEM} wireplumber wireplumber-\${INIT_SYSTEM}"

    elif [ "\${DESKTOP_ENV}" = "xfce" ]; then
        DE_PKGS="xorg-server xfce4 xfce4-whiskermenu-plugin xfce4-pulseaudio-plugin"
        DESKTOP_PKGS="kitty fastfetch sddm xclip maim sddm-\${INIT_SYSTEM} power-profiles-daemon power-profiles-daemon-\${INIT_SYSTEM} pipewire pipewire-\${INIT_SYSTEM} pipewire-pulse pipewire-pulse-\${INIT_SYSTEM} wireplumber wireplumber-\${INIT_SYSTEM}"

    else
        DE_PKGS=""
        DESKTOP_PKGS=""
        info "Skipping Desktop Environment installation."
    fi

    pacman -S \
        \${DE_PKGS} \
        \${DESKTOP_PKGS} \
        turnstile turnstile-\${INIT_SYSTEM} \
        networkmanager networkmanager-\${INIT_SYSTEM} \
        dbus dbus-\${INIT_SYSTEM} \
        neovim nano sudo \
        --noconfirm

    case "\${INIT_SYSTEM}" in
        openrc)
            rc-update add dbus default
            rc-update add elogind default
            rc-update add NetworkManager default
            rc-update add turnstile default
            if [ "\${DESKTOP_ENV}" != "none" ]; then
                rc-update add sddm default
                rc-update add power-profiles-daemon default
            fi
            ;;

        runit)
            mkdir -p /etc/runit/runsvdir/default
            for service in dbus elogind NetworkManager turnstiled; do
                if [ -d "/etc/runit/sv/\${service}" ] && [ ! -e "/etc/runit/runsvdir/default/\${service}" ]; then
                    ln -s "/etc/runit/sv/\${service}" "/etc/runit/runsvdir/default/\${service}"
                fi
            done
            if [ "\${DESKTOP_ENV}" != "none" ] &&
               [ -d "/etc/runit/sv/sddm" ] &&
               [ ! -e "/etc/runit/runsvdir/default/sddm" ]; then
                ln -s /etc/runit/sv/sddm /etc/runit/runsvdir/default/sddm
                ln -s /etc/runit/sv/power-profiles-daemon /etc/runit/runsvdir/default/power-profiles-daemon
            fi
            ;;

        dinit)
            ln -s ../dbus /etc/dinit.d/boot.d/
            ln -s ../elogind /etc/dinit.d/boot.d/
            ln -s ../NetworkManager /etc/dinit.d/boot.d/
            ln -s ../turnstiled /etc/dinit.d/boot.d/
            if [ "\${DESKTOP_ENV}" != "none" ]; then
                ln -s ../sddm /etc/dinit.d/boot.d/
                ln -s ../power-profiles-daemon /etc/dinit.d/boot.d/
            fi
            ;;
    esac

fi

info "Installing mesa drivers for intel, amd and nouveau..."
pacman -S mesa lib32-mesa \
  vulkan-intel lib32-vulkan-intel \
  vulkan-radeon lib32-vulkan-radeon \
  vulkan-nouveau lib32-vulkan-nouveau \
  vulkan-swrast lib32-vulkan-swrast \
  libva intel-media-driver --noconfirm --needed

info "Installing GRUB..."

if [ "\${BOOT_MODE}" = "uefi" ]; then
    pacman -S --noconfirm grub efibootmgr
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=visnux
else
    pacman -S --noconfirm grub
    grub-install --recheck "\${GRUB_DISK}"
fi

sed -i 's/GRUB_DISTRIBUTOR="Arch"/GRUB_DISTRIBUTOR="Visnux"/' /etc/default/grub
sed -i 's/GRUB_DISTRIBUTOR="Artix"/GRUB_DISTRIBUTOR="Visnux"/' /etc/default/grub

git clone https://github.com/realv1sta/larphub
cp -r larphub/neveraskmewhatthisis/Office-sidebar /boot/grub/themes
cp larphub/visnux.svg /usr/share/icons/hicolor/scalable/apps/visnux.svg
cp larphub/visnux.png /usr/share/pixmaps/visnux.png
mkdir -p ~/.config/fastfetch
chmod +x larphub/colorlogo.sh && cd larphub/ && ./colorlogo.sh > ~/.config/fastfetch/logo.txt
cp neveraskmewhatthisis/config.jsonc ~/.config/fastfetch/
mkdir -p /etc/skel/.config
cp -r neveraskmewhatthisis/xfce4 /etc/skel/.config/
cp -r neveraskmewhatthisis/fish /etc/skel/.config/
cp neveraskmewhatthisis/plasma-org.kde.plasma.desktop-appletsrc /etc/skel/.config/
git clone https://github.com/beamyyl/fastfetch
cp -r fastfetch/* /etc/skel/.config/
./colorlogo.sh > /etc/skel/.config/fastfetch/logo.txt
mkdir -p /usr/share/wallpapers/
cp -r walls/visnux-walls/* /usr/share/wallpapers/
cd ..
rm -rf larphub

echo 'GRUB_THEME=/boot/grub/themes/Office-sidebar/theme.txt' >> /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

echo ""
info "Set the ROOT password:"

while ! passwd; do
    warn "Password change failed or passwords did not match. Please try again."
done

echo ""
echo -e "\${CYAN}[INPUT]\${NC} Would you like to create a new user? (y/n)"
read -rp "  Choice: " CREATE_USER

if [[ "\${CREATE_USER}" =~ ^[Yy]$ ]]; then

    while true; do
        echo -e "\${CYAN}[INPUT]\${NC} Enter the new username:"
        read -rp "  Username: " NEW_USER

        if [ -n "\${NEW_USER}" ]; then
            break
        fi

        warn "Username cannot be empty. Please try again."
    done

    echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
    chmod 440 /etc/sudoers.d/wheel

    useradd -m -G wheel,audio,video,input -s /usr/bin/fish "\${NEW_USER}"

    info "User '\${NEW_USER}' created and added to: wheel, audio, video, input"
    info "Set a password for '\${NEW_USER}':"

    while ! passwd "\${NEW_USER}"; do
        warn "Password change failed or passwords did not match. Please try again."
    done

    info "Cloning and setting up dotfiles for '\${NEW_USER}'..."
    su - "\${NEW_USER}" -c "cd ~ && mkdir -p ~/.config && git clone https://github.com/beamyyl/maindots && cp -r maindots/* ~/.config/ && rm -rf maindots && [ ! -f ~/.config/fastfetch/config.jsonc ] || sed -i 's/\"top\": 2/\"top\": 1/' ~/.config/fastfetch/config.jsonc"
    info "Dotfiles installed successfully."
    info "User setup complete."

elif [[ "\${CREATE_USER}" =~ ^[Nn]$ ]]; then
    info "Skipping user creation."
else
    warn "Invalid choice '\${CREATE_USER}'. Skipping user creation."
fi

CHROOT_EOF

            chmod +x /mnt/root/chroot-install.sh
            arch-chroot /mnt /bin/bash /root/chroot-install.sh >> "$LOG_FILE" 2>&1

            rm -f /mnt/root/chroot-install.sh /tmp/visnux-artix-bootstrap.conf /tmp/visnux-artix.conf
            umount -R /mnt 2>/dev/null || true

            clear
            dialog --title "All done!" --msgbox "Visnux installed successfully! Remove installation media and reboot." 0 0; clear
            break
        fi
    fi

done
