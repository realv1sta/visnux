#!/bin/bash
set -u

USER_=""
PASSWORD=""
HOST=""
ROOT=""
INIT=""
DE=""

check_mount() {
    mountpoint -q /mnt
}

refresh_mirrors() {
    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup || true
    LOCATION=$(curl -s --max-time 5 https://ipinfo.io/country | tr -d '[:space:]')

    REFLECTOR_OK=true
    if [ -n "$LOCATION" ]; then
        reflector --country "$LOCATION" --latest 10 --protocol https --sort rate --download-timeout 5 --save /etc/pacman.d/mirrorlist || REFLECTOR_OK=false
    else
        REFLECTOR_OK=false
    fi

    if [ "$REFLECTOR_OK" = false ] || [ ! -s /etc/pacman.d/mirrorlist ]; then
        reflector --latest 10 --protocol https --sort rate --download-timeout 5 --save /etc/pacman.d/mirrorlist || true
    fi

    if [ ! -s /etc/pacman.d/mirrorlist ]; then
        [ -f /etc/pacman.d/mirrorlist.backup ] && cp /etc/pacman.d/mirrorlist.backup /etc/pacman.d/mirrorlist
    fi

    pacman -Syy --noconfirm archlinux-keyring
}

# Display welcome message before main menu loop
dialog --title "Visnux Linux" --msgbox "Welcome to Visnux Linux! Before running the installer, partition your drives. Because we do NOT make your drives, do em yourself\n\n With love,\n v1sta_" 0 0; clear

while true; do
    MENU=$(dialog --title "Installation Menu" --menu "Choose an option" 15 50 6 \
        1 "User Account" \
        2 "Hostname" \
        3 "Root Password" \
        4 "Init Selection" \
        5 "DE selection" \
        6 "Install" 3>&1 1>&2 2>&3 3>&-)
    
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
            if refresh_mirrors; then
                dialog --title "Mirrors" --msgbox "Mirrors updated!" 0 0; clear
            else
                dialog --title "Mirrors" --msgbox "Mirror update failed. Proceeding with system defaults." 0 0; clear
            fi
        fi
    fi
   
    if [ "$MENU" == "5" ]; then
        DE=$(dialog --title "DE Selection" --menu "Choose your preferred DE: " 12 40 2 \
            1 "KDE Plasma" \
            2 "XFCE4" 3>&1 1>&2 2>&3 3>&-); clear
    fi
   
    if [ "$MENU" == "6" ]; then

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

            # ================= SYSTEMD INSTALL =================
            if [ "$INIT" == "1" ]; then
                sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /etc/pacman.conf
                pacman -Sy archlinux-keyring --noconfirm

                pacstrap -K /mnt base base-devel linux linux-firmware sof-firmware grub efibootmgr sudo || INIT_OK=false
                genfstab -U /mnt > /mnt/etc/fstab

                sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /mnt/etc/pacman.conf
                sed -i '/^ParallelDownloads = 12/a Color\nILoveCandy' /mnt/etc/pacman.conf

                arch-chroot /mnt /bin/bash <<EOF
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
    systemctl enable NetworkManager
    systemctl enable sddm --force
elif [ "$DE" == "2" ]; then
    pacman -S xfce4 xfce4-whiskermenu-plugin xclip maim xfce4-pulseaudio-plugin kitty fastfetch sddm networkmanager nano sudo power-profiles-daemon --noconfirm
    systemctl enable NetworkManager
    systemctl enable sddm --force
fi
EOF
                [ $? -ne 0 ] && INIT_OK=false
            fi

            # ================= OPENRC INSTALL =================
            if [ "$INIT" == "2" ]; then
                ARTIX_BOOTSTRAP_CONF="/tmp/visnux-artix-bootstrap.conf"
                cat > "$ARTIX_BOOTSTRAP_CONF" <<EOF
[options]
Architecture = auto
ParallelDownloads = 12
SigLevel = Never

[system]
Server = https://artix.dingo.kiwi/\$repo/os/\$arch
EOF

                pacman-key --init
                pacman-key --populate artix

                pacman -Sy --config "$ARTIX_BOOTSTRAP_CONF" --noconfirm artix-keyring
                pacman-key --populate artix

                ARTIX_CONF="/tmp/visnux-artix.conf"
                cat > "$ARTIX_CONF" <<EOF
[options]
Architecture = auto
ParallelDownloads = 12
Color
CheckSpace
DatabaseOptional
SigLevel = Required
LocalFileSigLevel = Optional

[system]
Server = https://artix.dingo.kiwi/\$repo/os/\$arch

[world]
Server = https://artix.dingo.kiwi/\$repo/os/\$arch

[galaxy]
Server = https://artix.dingo.kiwi/\$repo/os/\$arch
EOF

                pacstrap -C "$ARTIX_CONF" /mnt base base-devel openrc elogind-openrc linux linux-firmware sof-firmware grub efibootmgr artix-keyring artix-mirrorlist sudo git || INIT_OK=false

                echo 'Server = https://mirrors.rit.edu/artixlinux/$repo/os/$arch' > /mnt/etc/pacman.d/mirrorlist
                sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /mnt/etc/pacman.conf
                sed -i '/^ParallelDownloads = 12/a Color\nILoveCandy' /mnt/etc/pacman.conf

                genfstab -U /mnt > /mnt/etc/fstab

                arch-chroot /mnt pacman -Sy --noconfirm artix-mirrorlist
                arch-chroot /mnt pacman -Sy --noconfirm artix-archlinux-support || true
                arch-chroot /mnt pacman-key --populate archlinux || true

                DE_PKGS=""
                DESKTOP_PKGS=""

                if [ "$DE" == "1" ]; then
                    DE_PKGS="plasma konsole dolphin"
                    DESKTOP_PKGS="kitty fastfetch wl-clipboard sddm sddm-openrc power-profiles-daemon power-profiles-daemon-openrc pipewire pipewire-openrc pipewire-pulse pipewire-pulse-openrc wireplumber wireplumber-openrc"
                elif [ "$DE" == "2" ]; then
                    DE_PKGS="xorg-server xfce4 xfce4-whiskermenu-plugin xfce4-pulseaudio-plugin"
                    DESKTOP_PKGS="kitty fastfetch sddm xclip maim sddm-openrc power-profiles-daemon power-profiles-daemon-openrc pipewire pipewire-openrc pipewire-pulse pipewire-pulse-openrc wireplumber wireplumber-openrc"
                fi

                arch-chroot /mnt /bin/bash <<EOF
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

pacman -S \
    $DE_PKGS \
    $DESKTOP_PKGS \
    turnstile turnstile-openrc \
    networkmanager networkmanager-openrc \
    dbus dbus-openrc \
    nano sudo \
    --noconfirm

rc-update add dbus default
rc-update add elogind default
rc-update add NetworkManager default
rc-update add turnstile default
rc-update add sddm default
rc-update add power-profiles-daemon default
EOF
                [ $? -ne 0 ] && INIT_OK=false
            fi

            # ================= RUNIT INSTALL =================
            if [ "$INIT" == "3" ]; then
                ARTIX_BOOTSTRAP_CONF="/tmp/visnux-artix-bootstrap.conf"
                cat > "$ARTIX_BOOTSTRAP_CONF" <<EOF
[options]
Architecture = auto
ParallelDownloads = 12
SigLevel = Never

[system]
Server = https://artix.dingo.kiwi/\$repo/os/\$arch
EOF

                pacman-key --init
                pacman-key --populate artix

                pacman -Sy --config "$ARTIX_BOOTSTRAP_CONF" --noconfirm artix-keyring
                pacman-key --populate artix

                ARTIX_CONF="/tmp/visnux-artix.conf"
                cat > "$ARTIX_CONF" <<EOF
[options]
Architecture = auto
ParallelDownloads = 12
Color
CheckSpace
DatabaseOptional
SigLevel = Required
LocalFileSigLevel = Optional

[system]
Server = https://artix.dingo.kiwi/\$repo/os/\$arch

[world]
Server = https://artix.dingo.kiwi/\$repo/os/\$arch

[galaxy]
Server = https://artix.dingo.kiwi/\$repo/os/\$arch
EOF

                pacstrap -C "$ARTIX_CONF" /mnt base base-devel runit runit-rc elogind-runit linux linux-firmware sof-firmware grub efibootmgr artix-keyring artix-mirrorlist sudo git || INIT_OK=false

                echo 'Server = https://mirrors.rit.edu/artixlinux/$repo/os/$arch' > /mnt/etc/pacman.d/mirrorlist
                sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /mnt/etc/pacman.conf
                sed -i '/^ParallelDownloads = 12/a Color\nILoveCandy' /mnt/etc/pacman.conf

                genfstab -U /mnt > /mnt/etc/fstab

                arch-chroot /mnt pacman -Sy --noconfirm artix-mirrorlist
                arch-chroot /mnt pacman -Sy --noconfirm artix-archlinux-support || true
                arch-chroot /mnt pacman-key --populate archlinux || true

                DE_PKGS=""
                DESKTOP_PKGS=""

                if [ "$DE" == "1" ]; then
                    DE_PKGS="plasma konsole dolphin"
                    DESKTOP_PKGS="kitty fastfetch wl-clipboard sddm sddm-runit power-profiles-daemon power-profiles-daemon-runit pipewire pipewire-runit pipewire-pulse pipewire-pulse-runit wireplumber wireplumber-runit"
                elif [ "$DE" == "2" ]; then
                    DE_PKGS="xorg-server xfce4 xfce4-whiskermenu-plugin xfce4-pulseaudio-plugin"
                    DESKTOP_PKGS="kitty fastfetch sddm xclip maim sddm-runit power-profiles-daemon power-profiles-daemon-runit pipewire pipewire-runit pipewire-pulse pipewire-pulse-runit wireplumber wireplumber-runit"
                fi

                arch-chroot /mnt /bin/bash <<EOF
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

pacman -S \
    $DE_PKGS \
    $DESKTOP_PKGS \
    turnstile turnstile-runit \
    networkmanager networkmanager-runit \
    dbus dbus-runit \
    nano sudo \
    --noconfirm

mkdir -p /etc/runit/runsvdir/default
mkdir -p /run/runit/service

for svc in dbus elogind networkmanager turnstiled sddm power-profiles-daemon; do
    if [ -d "/etc/runit/sv/\$svc" ]; then
        ln -sf "/etc/runit/sv/\$svc" /etc/runit/runsvdir/default/
        ln -sf "/etc/runit/sv/\$svc" /run/runit/service/
    fi
done
EOF
                [ $? -ne 0 ] && INIT_OK=false
            fi

            if [ "$INIT_OK" == "true" ]; then
                dialog --title "All done!" --msgbox "Installation complete! You can unmount /mnt and reboot into Visnux Linux." 0 0; clear
                break
            else
                dialog --title "Error" --msgbox "Installation encountered errors. Please check the terminal logs." 0 0; clear
            fi
        fi
    fi
        
done
