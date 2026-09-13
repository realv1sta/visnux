#!/bin/bash
set -u

USER_=""
PASSWORD=""
HOST=""
ROOT=""
INIT=""
DE=""
WIFI_SSID=""
WIFI_PASS=""
LOGFILE="/tmp/visnux_install.log"

check_mount() {
    mountpoint -q /mnt
}

show_error_log() {
    dialog --title "Installation Failed - Error Log" --textbox "$LOGFILE" 20 75; clear
}

fix_keyrings_and_time() {
    echo "=== Synchronizing System Time & Fixing Keyrings ===" >> "$LOGFILE"
    timedatectl set-ntp true 2>/dev/null || true
    pacman-key --init >> "$LOGFILE" 2>&1 || true
    pacman-key --populate artix archlinux >> "$LOGFILE" 2>&1 || true
}

setup_chroot_dns() {
    rm -f /mnt/etc/resolv.conf
    cat <<EOF > /mnt/etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
}

# Writes a NetworkManager keyfile connection profile straight into the
# target filesystem so the machine auto-joins Wi-Fi on first boot with
# zero manual nmtui/nmcli steps. No-op if the user skipped Wi-Fi setup
# (e.g. they're on ethernet).
setup_wifi_connection() {
    if [ -z "$WIFI_SSID" ]; then
        echo "=== No Wi-Fi SSID configured, skipping connection profile ===" >> "$LOGFILE"
        return 0
    fi

    echo "=== Writing NetworkManager connection profile for SSID: $WIFI_SSID ===" >> "$LOGFILE"

    mkdir -p /mnt/etc/NetworkManager/system-connections
    local uuid conn_file
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(date +%s)-0000-0000-0000-000000000000")
    conn_file="/mnt/etc/NetworkManager/system-connections/${WIFI_SSID}.nmconnection"

    {
        echo "[connection]"
        echo "id=$WIFI_SSID"
        echo "uuid=$uuid"
        echo "type=wifi"
        echo "autoconnect=true"
        echo ""
        echo "[wifi]"
        echo "mode=infrastructure"
        echo "ssid=$WIFI_SSID"
        echo ""
        if [ -n "$WIFI_PASS" ]; then
            echo "[wifi-security]"
            echo "key-mgmt=wpa-psk"
            echo "psk=$WIFI_PASS"
            echo ""
        fi
        echo "[ipv4]"
        echo "method=auto"
        echo ""
        echo "[ipv6]"
        echo "method=auto"
        echo "addr-gen-mode=default"
    } > "$conn_file"

    # NetworkManager refuses to load connection files that aren't
    # strictly root-owned and 600 - this is a hard requirement, not
    # a nicety, so get it right or wifi silently won't auto-connect.
    chmod 600 "$conn_file"
    chown root:root "$conn_file" 2>/dev/null || true
}

# Enables a service under a runit runsvdir by searching for the real
# directory name case-insensitively, instead of assuming exact casing.
# Different packages/versions ship different casing (NetworkManager vs
# networkmanager, turnstiled vs turnstile, etc) and a hardcoded name that
# doesn't match silently does nothing - this logs a clear warning instead.
enable_runit_service() {
    local pattern="$1"
    local svdir
    svdir=$(find /etc/runit/sv -maxdepth 1 -iname "$pattern" -print -quit 2>/dev/null)
    if [ -n "$svdir" ]; then
        ln -sf "$svdir" /etc/runit/runsvdir/default/
        echo "Enabled runit service: $svdir" >> /tmp/visnux_install.log 2>/dev/null || true
    else
        echo "WARNING: no runit service directory matching '$pattern' found under /etc/runit/sv - skipped" >&2
    fi
}

# Same idea for OpenRC: confirm the init script actually exists under
# /etc/init.d before calling rc-update, and search case-insensitively.
enable_openrc_service() {
    local pattern="$1"
    local svc
    svc=$(find /etc/init.d -maxdepth 1 -iname "$pattern" -print -quit 2>/dev/null)
    if [ -n "$svc" ]; then
        rc-update add "$(basename "$svc")" default
    else
        echo "WARNING: no OpenRC service matching '$pattern' found under /etc/init.d - skipped" >&2
    fi
}

refresh_mirrors() {
    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup || true
    LOCATION=$(curl -s --max-time 5 https://ipinfo.io/country | tr -d '[:space:]')

    REFLECTOR_OK=true
    if [ -n "$LOCATION" ]; then
        reflector --country "$LOCATION" --latest 10 --protocol https --sort rate --download-timeout 5 --save /etc/pacman.d/mirrorlist >> "$LOGFILE" 2>&1 || REFLECTOR_OK=false
    else
        REFLECTOR_OK=false
    fi

    if [ "$REFLECTOR_OK" = false ] || [ ! -s /etc/pacman.d/mirrorlist ]; then
        reflector --latest 10 --protocol https --sort rate --download-timeout 5 --save /etc/pacman.d/mirrorlist >> "$LOGFILE" 2>&1 || true
    fi

    if [ ! -s /etc/pacman.d/mirrorlist ]; then
        [ -f /etc/pacman.d/mirrorlist.backup ] && cp /etc/pacman.d/mirrorlist.backup /etc/pacman.d/mirrorlist
    fi

    pacman -Syy --noconfirm archlinux-keyring artix-keyring >> "$LOGFILE" 2>&1 || true
}

> "$LOGFILE"

dialog --title "Visnux Linux" --msgbox "Welcome to Visnux Linux! Before running the installer, partition your drives. Because we do NOT make your drives, do em yourself\n\n With love,\n v1sta_" 0 0; clear

while true; do
    MENU=$(dialog --title "Installation Menu" --menu "Choose an option" 17 55 7 \
        1 "User Account" \
        2 "Hostname" \
        3 "Root Password" \
        4 "Init Selection" \
        5 "DE selection" \
        6 "Wi-Fi Setup (optional)" \
        7 "Install" 3>&1 1>&2 2>&3 3>&-)
    
    STATUS=$?
    clear

    if [ $STATUS -ne 0 ]; then
        break
    fi
    
    if [ "$MENU" == "1" ]; then
        while true; do
            USER_=$(dialog --title "User Creation" --inputbox "Please write a name for your user: " 0 0 3>&1 1>&2 2>&3 3>&-); clear
            [ -n "$USER_" ] && break
        done
        
        while true; do
            PASSWORD=$(dialog --title "Password" --insecure --passwordbox "Please make a password for: $USER_" 0 0 3>&1 1>&2 2>&3 3>&-); clear
            PASSWORD2=$(dialog --title "Password" --insecure --passwordbox "Please retype the password for: $USER_" 0 0 3>&1 1>&2 2>&3 3>&-); clear
            
            if [ -n "$PASSWORD" ] && [ "$PASSWORD" == "$PASSWORD2" ]; then
                dialog --title "Password Set!" --msgbox "Password has been set!" 0 0; clear
                break
            else
                dialog --title "Error" --msgbox "Passwords do not match or were left empty. Try again." 0 0; clear
            fi
        done
    fi
    
    if [ "$MENU" == "2" ]; then
        while true; do
            HOST=$(dialog --title "Hostname" --inputbox "Create your hostname: " 0 0 3>&1 1>&2 2>&3 3>&-); clear
            [ -n "$HOST" ] && break
        done
        dialog --title "Success!" --msgbox "Your host name will be: $HOST." 0 0; clear
    fi
    
    if [ "$MENU" == "3" ]; then
        while true; do
            ROOT=$(dialog --title "Root password" --insecure --passwordbox "Please type in your root password: " 0 0 3>&1 1>&2 2>&3 3>&-); clear
            ROOT2=$(dialog --title "Root password" --insecure --passwordbox "Please retype your root password: " 0 0 3>&1 1>&2 2>&3 3>&-); clear
        
            if [ -n "$ROOT" ] && [ "$ROOT" == "$ROOT2" ]; then
                dialog --title "Root Password Set!" --msgbox "Your root password has been set!" 0 0; clear
                break
            else
                dialog --title "Error" --msgbox "Passwords do not match or were left empty. Try again." 0 0; clear
            fi
        done
    fi
   
    if [ "$MENU" == "4" ]; then
        INIT=$(dialog --title "Init Selection" --menu "Choose your preferred init: " 12 40 3 \
            1 "systemd" \
            2 "openrc" \
            3 "runit" 3>&1 1>&2 2>&3 3>&-); clear

        if [ -n "$INIT" ]; then
            dialog --title "Mirrors" --infobox "Finding fast mirrors for your location, hang on..." 0 0
            refresh_mirrors
            dialog --title "Mirrors" --msgbox "Mirrors updated!" 0 0; clear
        fi
    fi
   
    if [ "$MENU" == "5" ]; then
        DE=$(dialog --title "DE Selection" --menu "Choose your preferred DE: " 12 40 2 \
            1 "KDE Plasma" \
            2 "XFCE4" 3>&1 1>&2 2>&3 3>&-); clear
    fi

    if [ "$MENU" == "6" ]; then
        dialog --title "Wi-Fi Setup" --yesno "Do you want to pre-configure a Wi-Fi network?\n\nOn ethernet? Choose No - NetworkManager handles wired connections automatically, no setup needed." 0 0
        if [ $? -eq 0 ]; then
            while true; do
                WIFI_SSID=$(dialog --title "Wi-Fi Setup" --inputbox "Enter the Wi-Fi network name (SSID): " 0 0 3>&1 1>&2 2>&3 3>&-); clear
                [ -n "$WIFI_SSID" ] && break
                dialog --title "Error" --msgbox "SSID cannot be empty." 0 0; clear
            done

            dialog --title "Wi-Fi Setup" --yesno "Is this an open network (no password)?" 0 0
            if [ $? -eq 0 ]; then
                WIFI_PASS=""
            else
                while true; do
                    WIFI_PASS=$(dialog --title "Wi-Fi Setup" --insecure --passwordbox "Enter the Wi-Fi password for: $WIFI_SSID" 0 0 3>&1 1>&2 2>&3 3>&-); clear
                    WIFI_PASS2=$(dialog --title "Wi-Fi Setup" --insecure --passwordbox "Retype the Wi-Fi password: " 0 0 3>&1 1>&2 2>&3 3>&-); clear
                    if [ -n "$WIFI_PASS" ] && [ "$WIFI_PASS" == "$WIFI_PASS2" ]; then
                        break
                    else
                        dialog --title "Error" --msgbox "Passwords do not match or were left empty. Try again." 0 0; clear
                    fi
                done
            fi
            dialog --title "Wi-Fi Set!" --msgbox "Wi-Fi network '$WIFI_SSID' will be pre-configured and auto-connect on first boot." 0 0; clear
        else
            WIFI_SSID=""
            WIFI_PASS=""
            clear
        fi
    fi
   
    if [ "$MENU" == "7" ]; then

        MISSING=""
        [ -z "$USER_" ] && MISSING="${MISSING}\n - User Account"
        [ -z "$HOST" ] && MISSING="${MISSING}\n - Hostname"
        [ -z "$ROOT" ] && MISSING="${MISSING}\n - Root Password"
        [ -z "$INIT" ] && MISSING="${MISSING}\n - Init Selection"
        [ -z "$DE" ] && MISSING="${MISSING}\n - DE Selection"

        if [ -n "$MISSING" ]; then
            dialog --title "Missing Fields" --msgbox "Please configure the following options first:\n$MISSING" 0 0; clear
            continue
        fi

        if ! check_mount; then
            dialog --title "Mount Error" --msgbox "Nothing is mounted at /mnt! Please partition and mount your target drive before installing." 0 0; clear
            continue
        fi

        dialog --title "Warning!" --yesno "If you click confirm, Visnux Linux will install on your disk/partition at /mnt. THIS ACTION CANNOT BE REVERSED!\n\nDo you wish to continue?" 0 0
        
        STATUS=$?
        clear
      
        if [ $STATUS -ne 0 ]; then
            break
        else
            TIMEZONE=$(curl -s --max-time 5 https://ipinfo.io/timezone)
            if [ -z "$TIMEZONE" ] || [ ! -e "/usr/share/zoneinfo/$TIMEZONE" ]; then
                TIMEZONE="UTC"
            fi

            INIT_OK=true
            fix_keyrings_and_time

            # ================= SYSTEMD INSTALL =================
            if [ "$INIT" == "1" ]; then
                sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /etc/pacman.conf
                
                pacstrap -K /mnt base base-devel linux linux-firmware sof-firmware grub efibootmgr sudo >> "$LOGFILE" 2>&1 || INIT_OK=false
                
                if [ "$INIT_OK" == "true" ]; then
                    genfstab -U /mnt > /mnt/etc/fstab
                    setup_chroot_dns
                    setup_wifi_connection

                    sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /mnt/etc/pacman.conf
                    sed -i '/^ParallelDownloads = 12/a Color\nILoveCandy' /mnt/etc/pacman.conf

                    arch-chroot /mnt /bin/bash >> "$LOGFILE" 2>&1 <<EOF
pacman -Sy --noconfirm archlinux-keyring || true

# Set DNS (not locked - NetworkManager needs to manage this after install)
echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf
echo "$HOST" > /etc/hostname

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

cat <<HOSTSEOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOST.localdomain $HOST
HOSTSEOF

mkinitcpio -P

cat <<OSSEOF > /etc/os-release
NAME="Visnux"
PRETTY_NAME="Visnux Linux"
ID=visnux
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;85;255;85"
HOME_URL="https://visnux.duckdns.org/"
DOCUMENTATION_URL="https://visnux.duckdns.org/"
LOGO=linux
OSSEOF

echo "root:$ROOT" | chpasswd
useradd -m -G wheel "$USER_"
echo "$USER_:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

sed -i 's/^#*GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Visnux"/' /etc/default/grub || echo 'GRUB_DISTRIBUTOR="Visnux"' >> /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Visnux || grub-install /dev/sda
grub-mkconfig -o /boot/grub/grub.cfg

if [ "$DE" == "1" ]; then
    pacman -S plasma konsole dolphin wl-clipboard kitty fastfetch sddm networkmanager nano sudo power-profiles-daemon --noconfirm
elif [ "$DE" == "2" ]; then
    pacman -S xorg-server xfce4 xfce4-whiskermenu-plugin xclip maim xfce4-pulseaudio-plugin kitty fastfetch sddm networkmanager nano sudo power-profiles-daemon --noconfirm
fi

systemctl enable NetworkManager
systemctl enable sddm --force
EOF
                    [ $? -ne 0 ] && INIT_OK=false
                fi
            fi

            # ================= OPENRC INSTALL =================
            if [ "$INIT" == "2" ]; then
                ARTIX_CONF="/tmp/visnux-artix.conf"
                cat > "$ARTIX_CONF" <<EOF
[options]
Architecture = auto
ParallelDownloads = 12
Color
CheckSpace
DatabaseOptional
SigLevel = Optional TrustAll

[system]
Server = https://artix.dingo.kiwi/\$repo/os/\$arch
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch

[world]
Server = https://artix.dingo.kiwi/\$repo/os/\$arch
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch

[galaxy]
Server = https://artix.dingo.kiwi/\$repo/os/\$arch
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch
EOF

                pacstrap -C "$ARTIX_CONF" /mnt base base-devel openrc elogind-openrc linux linux-firmware sof-firmware grub efibootmgr artix-keyring archlinux-keyring artix-mirrorlist sudo git >> "$LOGFILE" 2>&1 || INIT_OK=false

                if [ "$INIT_OK" == "true" ]; then
                    sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /mnt/etc/pacman.conf
                    sed -i '/^ParallelDownloads = 12/a Color\nILoveCandy' /mnt/etc/pacman.conf

                    genfstab -U /mnt > /mnt/etc/fstab
                    setup_chroot_dns
                    setup_wifi_connection

                    arch-chroot /mnt /bin/bash >> "$LOGFILE" 2>&1 <<EOF
# Set DNS (not locked - NetworkManager needs to manage this after install)
echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf

pacman-key --init
pacman-key --populate artix archlinux
pacman -Sy --noconfirm artix-mirrorlist artix-keyring archlinux-keyring artix-archlinux-support || true

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf
echo "$HOST" > /etc/hostname

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

cat <<HOSTSEOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOST.localdomain $HOST
HOSTSEOF

cat <<OSSEOF > /etc/os-release
NAME="Visnux"
PRETTY_NAME="Visnux Linux"
ID=visnux
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;85;255;85"
HOME_URL="https://visnux.duckdns.org/"
DOCUMENTATION_URL="https://visnux.duckdns.org/"
LOGO=linux
OSSEOF

echo "root:$ROOT" | chpasswd
useradd -m -G wheel "$USER_"
echo "$USER_:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

mkinitcpio -P

sed -i 's/^#*GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Visnux"/' /etc/default/grub || echo 'GRUB_DISTRIBUTOR="Visnux"' >> /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Visnux || grub-install /dev/sda
grub-mkconfig -o /boot/grub/grub.cfg

DE_PKGS=""
DESKTOP_PKGS=""

if [ "$DE" == "1" ]; then
    DE_PKGS="plasma konsole dolphin"
    DESKTOP_PKGS="kitty fastfetch wl-clipboard sddm sddm-openrc power-profiles-daemon power-profiles-daemon-openrc pipewire pipewire-openrc pipewire-pulse pipewire-pulse-openrc wireplumber wireplumber-openrc"
elif [ "$DE" == "2" ]; then
    DE_PKGS="xorg-server xfce4 xfce4-whiskermenu-plugin xfce4-pulseaudio-plugin"
    DESKTOP_PKGS="kitty fastfetch sddm xclip maim sddm-openrc power-profiles-daemon power-profiles-daemon-openrc pipewire pipewire-openrc pipewire-pulse pipewire-pulse-openrc wireplumber wireplumber-openrc"
fi

pacman -S \
    \$DE_PKGS \
    \$DESKTOP_PKGS \
    turnstile turnstile-openrc \
    networkmanager networkmanager-openrc \
    dbus dbus-openrc \
    nano sudo \
    --noconfirm
EOF
                    [ $? -ne 0 ] && INIT_OK=false

                    if [ "$INIT_OK" == "true" ]; then
                        echo "=== Enabling OpenRC services (self-detecting) ===" >> "$LOGFILE"
                        arch-chroot /mnt /bin/bash >> "$LOGFILE" 2>&1 <<'SVCEOF'
enable_openrc_service() {
    local pattern="$1"
    local svc
    svc=$(find /etc/init.d -maxdepth 1 -iname "$pattern" -print -quit 2>/dev/null)
    if [ -n "$svc" ]; then
        rc-update add "$(basename "$svc")" default
        echo "Enabled OpenRC service: $(basename "$svc")"
    else
        echo "WARNING: no OpenRC service matching '$pattern' found under /etc/init.d - skipped" >&2
    fi
}

for svc in dbus elogind NetworkManager turnstile sddm power-profiles-daemon; do
    enable_openrc_service "$svc"
done
SVCEOF
                        [ $? -ne 0 ] && INIT_OK=false
                    fi
                fi
                rm -f "$ARTIX_CONF"
            fi

            # ================= RUNIT INSTALL =================
            if [ "$INIT" == "3" ]; then
                ARTIX_CONF="/tmp/visnux-artix.conf"
                cat > "$ARTIX_CONF" <<EOF
[options]
Architecture = auto
ParallelDownloads = 12
Color
CheckSpace
DatabaseOptional
SigLevel = Optional TrustAll

[system]
Server = https://artix.dingo.kiwi/\$repo/os/\$arch
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch

[world]
Server = https://artix.dingo.kiwi/\$repo/os/\$arch
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch

[galaxy]
Server = https://artix.dingo.kiwi/\$repo/os/\$arch
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch
EOF

                pacstrap -C "$ARTIX_CONF" /mnt base base-devel runit runit-rc elogind-runit linux linux-firmware sof-firmware grub efibootmgr artix-keyring archlinux-keyring artix-mirrorlist sudo git >> "$LOGFILE" 2>&1 || INIT_OK=false

                if [ "$INIT_OK" == "true" ]; then
                    sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /mnt/etc/pacman.conf
                    sed -i '/^ParallelDownloads = 12/a Color\nILoveCandy' /mnt/etc/pacman.conf

                    genfstab -U /mnt > /mnt/etc/fstab
                    setup_chroot_dns
                    setup_wifi_connection

                    arch-chroot /mnt /bin/bash >> "$LOGFILE" 2>&1 <<EOF
# Set DNS (not locked - NetworkManager needs to manage this after install)
rm -f /etc/resolv.conf
cat <<RESOLVEOF > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
RESOLVEOF

pacman-key --init
pacman-key --populate artix archlinux
pacman -Sy --noconfirm artix-mirrorlist artix-keyring archlinux-keyring artix-archlinux-support || true

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf
echo "$HOST" > /etc/hostname

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

cat <<HOSTSEOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOST.localdomain $HOST
HOSTSEOF

cat <<OSSEOF > /etc/os-release
NAME="Visnux"
PRETTY_NAME="Visnux Linux"
ID=visnux
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;85;255;85"
HOME_URL="https://visnux.duckdns.org/"
DOCUMENTATION_URL="https://visnux.duckdns.org/"
LOGO=linux
OSSEOF

echo "root:$ROOT" | chpasswd
useradd -m -G wheel "$USER_"
echo "$USER_:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

mkinitcpio -P

sed -i 's/^#*GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Visnux"/' /etc/default/grub || echo 'GRUB_DISTRIBUTOR="Visnux"' >> /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Visnux || grub-install /dev/sda
grub-mkconfig -o /boot/grub/grub.cfg

DE_PKGS=""
DESKTOP_PKGS=""

if [ "$DE" == "1" ]; then
    DE_PKGS="plasma konsole dolphin"
    DESKTOP_PKGS="kitty fastfetch wl-clipboard sddm sddm-runit power-profiles-daemon power-profiles-daemon-runit pipewire pipewire-runit pipewire-pulse pipewire-pulse-runit wireplumber wireplumber-runit"
elif [ "$DE" == "2" ]; then
    DE_PKGS="xorg-server xfce4 xfce4-whiskermenu-plugin xfce4-pulseaudio-plugin"
    DESKTOP_PKGS="kitty fastfetch sddm xclip maim sddm-runit power-profiles-daemon power-profiles-daemon-runit pipewire pipewire-runit pipewire-pulse pipewire-pulse-runit wireplumber wireplumber-runit"
fi

pacman -S \
    \$DE_PKGS \
    \$DESKTOP_PKGS \
    turnstile turnstile-runit \
    networkmanager networkmanager-runit \
    dbus dbus-runit \
    nano sudo \
    --noconfirm
EOF
                    [ $? -ne 0 ] && INIT_OK=false

                    if [ "$INIT_OK" == "true" ]; then
                        echo "=== Enabling runit services (self-detecting) ===" >> "$LOGFILE"
                        arch-chroot /mnt /bin/bash >> "$LOGFILE" 2>&1 <<'SVCEOF'
mkdir -p /etc/runit/runsvdir/default

enable_runit_service() {
    local pattern="$1"
    local svdir
    svdir=$(find /etc/runit/sv -maxdepth 1 -iname "$pattern" -print -quit 2>/dev/null)
    if [ -n "$svdir" ]; then
        ln -sf "$svdir" /etc/runit/runsvdir/default/
        echo "Enabled runit service: $svdir"
    else
        echo "WARNING: no runit service directory matching '$pattern' found under /etc/runit/sv - skipped" >&2
    fi
}

echo "--- contents of /etc/runit/sv for reference ---"
ls /etc/runit/sv 2>&1

for svc in dbus elogind NetworkManager turnstiled sddm power-profiles-daemon; do
    enable_runit_service "$svc"
done
SVCEOF
                        [ $? -ne 0 ] && INIT_OK=false
                    fi
                fi
                rm -f "$ARTIX_CONF"
            fi

            if [ "$INIT_OK" == "true" ]; then
                dialog --title "All done!" --msgbox "Installation complete! Reboot into Visnux Linux to launch SDDM." 0 0; clear
                break
            else
                show_error_log
            fi
        fi
    fi
        
done
