#!/bin/bash

set -u

dialog --title "Visnux Linux" --msgbox "Welcome to Visnux Linux! Before running the installer, partition your drives. Because we do NOT make your drives, do em yourself\n\n With love,\n v1sta_" 0 0; clear

check_mount() {
    if ! mountpoint -q /mnt; then
        return 1
    fi
    return 0
}

refresh_mirrors() {
    pacman -Sy --noconfirm reflector curl || return 1

    echo "Finding mirrors for your location..."
    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

    LOCATION=$(curl -s --max-time 5 https://ipinfo.io/country | tr -d '[:space:]')

    REFLECTOR_OK=true
    if [ -n "$LOCATION" ]; then
        reflector --country "$LOCATION" --latest 10 --protocol https --sort rate --download-timeout 5 --save /etc/pacman.d/mirrorlist || REFLECTOR_OK=false
    else
        REFLECTOR_OK=false
    fi

    if [ "$REFLECTOR_OK" = false ] || [ ! -s /etc/pacman.d/mirrorlist ]; then
        echo "Country-specific mirrors unavailable, trying global mirrors..."
        reflector --latest 10 --protocol https --sort rate --download-timeout 5 --save /etc/pacman.d/mirrorlist
    fi

    if [ ! -s /etc/pacman.d/mirrorlist ]; then
        echo "Reflector failed, restoring default mirrorlist..."
        cp /etc/pacman.d/mirrorlist.backup /etc/pacman.d/mirrorlist
    fi

    pacman -Syy --noconfirm archlinux-keyring
}

while true; do
    MENU=$(dialog --title "Installation Menu" --menu "Choose an option" 15 50 6 1 "User Account" 2 "Hostname" 3 "Root Password" 4 "Init Selection" 5 "DE selection" 6 "Install" 3>&1 1>&2 2>&3 3>&-)
    
    STATUS=$?
    clear

    if [ $STATUS -ne 0 ]; then
        echo "You stopped the Instalation Process"
        break
    fi
    
    if [ "$MENU" == "1" ]; then
        while true; do
            USER_=$(dialog --title "User Creation" --inputbox "Please write a name for your user: " 0 0 3>&1 1>&2 2>&3 3>&-); clear
            if [ -z "$USER_" ]; then
                continue
            fi
            break
        done
        
        while true; do
            PASSWORD=$(dialog --title "Password" --insecure --passwordbox "Please make a password for: $USER_" 0 0 3>&1 1>&2 2>&3 3>&-); clear
            PASSWORD2=$(dialog --title "Password" --insecure --passwordbox "Please retype the password for: $USER_" 0 0 3>&1 1>&2 2>&3 3>&-); clear
            
            if [ -n "$PASSWORD" ] && [ "$PASSWORD" == "$PASSWORD2" ]; then
                dialog --title "Password Set!" --msgbox "Password has been set!" 0 0; clear
                break
            fi
        done
    fi
    
    if [ "$MENU" == "2" ]; then
        while true; do
            HOST=$(dialog --title "Hostname" --inputbox "Create your hostname: " 0 0 3>&1 1>&2 2>&3 3>&-); clear
            if [ -z "$HOST" ]; then
                continue
            fi
            break
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
            fi
        done
    fi
   
    if [ "$MENU" == "4" ]; then
        INIT=$(dialog --title "Init Selection" --menu "Choose your prefered init: " 12 40 3 1 "systemd" 2 "openrc" 3 "runit" 3>&1 1>&2 2>&3 3>&-); clear

        if [ -n "$INIT" ]; then
            dialog --title "Mirrors" --infobox "Finding fast mirrors for your location, hang on..." 0 0
            if refresh_mirrors; then
                MIRRORS_OK=true
                dialog --title "Mirrors" --msgbox "Mirrors updated!" 0 0; clear
            else
                MIRRORS_OK=false
                clear
            fi
        fi
    fi
   
    if [ "$MENU" == "5" ]; then
        DE=$(dialog --title "DE Selection" --menu "Choose your prefered DE: " 12 40 2 1 "KDE Plasma" 2 "XFCE4" 3>&1 1>&2 2>&3 3>&-); clear
    fi
   
    if [ "$MENU" == "6" ]; then

        MISSING=""
        [ -z "${USER_:-}" ] && MISSING="${MISSING}\n - User Account"
        [ -z "${HOST:-}" ] && MISSING="${MISSING}\n - Hostname"
        [ -z "${ROOT:-}" ] && MISSING="${MISSING}\n - Root Password"
        [ -z "${INIT:-}" ] && MISSING="${MISSING}\n - Init Selection"
        [ -z "${DE:-}" ] && MISSING="${MISSING}\n - DE selection"

        if [ -n "$MISSING" ]; then
            continue
        fi

        if ! check_mount; then
            continue
        fi

        dialog --title "Warning!" --yesno "If you click confirm, Visnux Linux will install on your disk/partition. THIS ACTION CANT BE REVERSED! Soo do it at ur own risk <3" 0 0
        
        STATUS=$?
        clear
      
        if [ $STATUS -ne 0 ]; then
            echo "You stopped the Instalation Process"
            echo "PS: we dont save anything so you gotta do evreything again :("
            break
        else
            TIMEZONE=$(curl -s https://ipinfo.io/timezone)
            if [ -z "$TIMEZONE" ] || [ ! -e "/usr/share/zoneinfo/$TIMEZONE" ]; then
                TIMEZONE="UTC"
            fi

            INIT_OK=true

# =============================================================================
# SYSTEMD INSTALLATION
# =============================================================================
            if [ "$INIT" == "1" ]; then
                sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /etc/pacman.conf
                pacman -Sy archlinux-keyring --noconfirm

                pacstrap -K /mnt base base-devel linux linux-firmware sof-firmware grub efibootmgr sudo || INIT_OK=false
                genfstab -U /mnt > /mnt/etc/fstab

                sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /mnt/etc/pacman.conf
                sed -i '/^ParallelDownloads = 12/a Color\nILoveCandy' /mnt/etc/pacman.conf

                arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf
echo "$HOST" > /etc/hostname

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
LOGO=visnux
OSSEOF

echo "root:$ROOT" | chpasswd
useradd -m -G wheel $USER_
echo "$USER_:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || grub-install /dev/sda
grub-mkconfig -o /boot/grub/grub.cfg

if [ "$DE" == "1" ]; then
    pacman -S plasma konsole dolphin wl-clipboard kitty fastfetch sddm networkmanager neovim nano sudo power-profiles-daemon --noconfirm
    systemctl enable NetworkManager
    systemctl enable sddm --force
elif [ "$DE" == "2" ]; then
    pacman -S xfce4 xfce4-whiskermenu-plugin xclip maim xfce4-pulseaudio-plugin kitty fastfetch sddm networkmanager neovim nano sudo power-profiles-daemon --noconfirm
    systemctl enable NetworkManager
    systemctl enable sddm --force
fi
EOF
                [ $? -ne 0 ] && INIT_OK=false
            fi

# =============================================================================
# OPENRC INSTALLATION
# =============================================================================
            if [ "$INIT" == "2" ]; then
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

                pacman --config "$ARTIX_BOOTSTRAP_CONF" -Sy --noconfirm artix-keyring
                pacman-key --init
                pacman-key --populate artix

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

                pacstrap -C "$ARTIX_CONF" /mnt base base-devel linux linux-firmware sof-firmware artix-keyring artix-mirrorlist openrc elogind-openrc grub efibootmgr sudo git || INIT_OK=false

                echo 'Server = https://mirrors.rit.edu/artixlinux/$repo/os/$arch' > /mnt/etc/pacman.d/mirrorlist
                sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /mnt/etc/pacman.conf
                sed -i '/^ParallelDownloads = 12/a Color\nILoveCandy' /mnt/etc/pacman.conf

                genfstab -U /mnt > /mnt/etc/fstab

                arch-chroot /mnt pacman -Sy --noconfirm artix-mirrorlist
                arch-chroot /mnt pacman -Sy --noconfirm artix-archlinux-support
                arch-chroot /mnt pacman-key --populate archlinux

                arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf
echo "$HOST" > /etc/hostname

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
LOGO=visnux
OSSEOF

echo "root:$ROOT" | chpasswd
useradd -m -G wheel $USER_
echo "$USER_:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

mkinitcpio -P

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || grub-install /dev/sda
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
    neovim nano sudo \
    --noconfirm

rc-update add dbus default
rc-update add elogind default
rc-update add NetworkManager default
rc-update add turnstile default
if [ "$DE" != "none" ]; then
    rc-update add sddm default
    rc-update add power-profiles-daemon default
fi
EOF
                [ $? -ne 0 ] && INIT_OK=false
            fi

# =============================================================================
# RUNIT INSTALLATION
# =============================================================================
            if [ "$INIT" == "3" ]; then
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

                pacman --config "$ARTIX_BOOTSTRAP_CONF" -Sy --noconfirm artix-keyring
                pacman-key --init
                pacman-key --populate artix

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

                pacstrap -C "$ARTIX_CONF" /mnt base base-devel linux linux-firmware sof-firmware artix-keyring artix-mirrorlist runit runit-rc elogind-runit grub efibootmgr sudo git || INIT_OK=false

                echo 'Server = https://mirrors.rit.edu/artixlinux/$repo/os/$arch' > /mnt/etc/pacman.d/mirrorlist
                sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /mnt/etc/pacman.conf
                sed -i '/^ParallelDownloads = 12/a Color\nILoveCandy' /mnt/etc/pacman.conf

                genfstab -U /mnt > /mnt/etc/fstab

                arch-chroot /mnt pacman -Sy --noconfirm artix-mirrorlist
                arch-chroot /mnt pacman -Sy --noconfirm artix-archlinux-support
                arch-chroot /mnt pacman-key --populate archlinux

                arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf
echo "$HOST" > /etc/hostname

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
LOGO=visnux
OSSEOF

echo "root:$ROOT" | chpasswd
useradd -m -G wheel $USER_
echo "$USER_:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

mkinitcpio -P

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || grub-install /dev/sda
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
    neovim nano sudo \
    --noconfirm

mkdir -p /etc/runit/runsvdir/default
for service in dbus elogind NetworkManager turnstiled; do
    if [ -d "/etc/runit/sv/\${service}" ] && [ ! -e "/etc/runit/runsvdir/default/\${service}" ]; then
        ln -s "/etc/runit/sv/\${service}" "/etc/runit/runsvdir/default/\${service}"
    fi
done

if [ "$DE" != "none" ] && [ -d "/etc/runit/sv/sddm" ] && [ ! -e "/etc/runit/runsvdir/default/sddm" ]; then
    ln -s /etc/runit/sv/sddm /etc/runit/runsvdir/default/sddm
    ln -s /etc/runit/sv/power-profiles-daemon /etc/runit/runsvdir/default/power-profiles-daemon
fi
EOF
                [ $? -ne 0 ] && INIT_OK=false
            fi

            if [ "$INIT_OK" == "true" ]; then
                dialog --title "All done!" --msgbox "You installed! You can reboot the system." 0 0; clear
            fi
        fi
    fi
        
done
