#!/bin/bash

set -u

dialog --title "Visnux Linux" --msgbox "Welcome to Visnux Linux! Before running the installer, partition your drives. Because we do NOT make your drives, do em yourself\n\n With love,\n v1sta_" 0 0; clear

check_mount() {
    if ! mountpoint -q /mnt; then
        dialog --title "BRO" --msgbox "Mount your drivers BETTER noob. I see no /mnt >:(" 0 0; clear
        return 1
    fi
    return 0
}

refresh_mirrors() {
    # Silenced stdout and stderr to stop stdout corruption breaking the dialog loop
    pacman -Sy --noconfirm reflector curl >/dev/null 2>&1 || return 1

    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

    LOCATION=$(curl -s --max-time 5 https://ipinfo.io/country | tr -d '[:space:]')

    REFLECTOR_OK=true
    if [ -n "$LOCATION" ]; then
        reflector --country "$LOCATION" --latest 10 --protocol https --sort rate --download-timeout 5 --save /etc/pacman.d/mirrorlist >/dev/null 2>&1 || REFLECTOR_OK=false
    else
        REFLECTOR_OK=false
    fi

    if [ "$REFLECTOR_OK" = false ] || [ ! -s /etc/pacman.d/mirrorlist ]; then
        reflector --latest 10 --protocol https --sort rate --download-timeout 5 --save /etc/pacman.d/mirrorlist >/dev/null 2>&1
    fi

    if [ ! -s /etc/pacman.d/mirrorlist ]; then
        cp /etc/pacman.d/mirrorlist.backup /etc/pacman.d/mirrorlist
    fi

    pacman -Syy --noconfirm archlinux-keyring >/dev/null 2>&1
}

USER_=""
HOST=""
ROOT=""
INIT=""
DE=""

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
        echo "You stopped the Installation Process"
        break
    fi
    
    if [ "$MENU" == "1" ]; then
        while true; do
            USER_=$(dialog --title "User Creation" --inputbox "Please write a name for your user: " 0 0 3>&1 1>&2 2>&3 3>&-); clear
            if [ -z "$USER_" ]; then
                dialog --title "Uh oh.." --msgbox "You can't leave the username blank, try again" 0 0; clear
                continue
            fi
            break
        done
        
        while true; do
            PASSWORD=$(dialog --title "Password" --insecure --passwordbox "Please make a password for: $USER_" 0 0 3>&1 1>&2 2>&3 3>&-); clear
            PASSWORD2=$(dialog --title "Password" --insecure --passwordbox "Please retype the password for: $USER_" 0 0 3>&1 1>&2 2>&3 3>&-); clear
            
            if [ -z "$PASSWORD" ]; then
                dialog --title "Uh oh.." --msgbox "Whoops, your secure passwords didn't match, try again" 0 0; clear
            elif [ "$PASSWORD" == "$PASSWORD2" ]; then
                dialog --title "Password Set!" --msgbox "Password has been set!" 0 0; clear
                break
            else
                dialog --title "Uh oh.." --msgbox "Whoops, your secure passwords didn't match, try again" 0 0; clear
            fi
        done
    fi
    
    if [ "$MENU" == "2" ]; then
        while true; do
            HOST=$(dialog --title "Hostname" --inputbox "Create your hostname: " 0 0 3>&1 1>&2 2>&3 3>&-); clear
            if [ -z "$HOST" ]; then
                dialog --title "Uh oh.." --msgbox "You can't leave the hostname blank, try again" 0 0; clear
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
        
            if [ -z "$ROOT" ]; then
                dialog --title "Whoopsies..?" --msgbox "Yeah buddy you messed up your root password, re-do it bud" 0 0; clear
            elif [ "$ROOT" == "$ROOT2" ]; then
                dialog --title "Root Password Set!" --msgbox "Your root password has been set!" 0 0; clear
                break
            else
                dialog --title "Whoopsies..?" --msgbox "Yeah buddy you messed up your root password, re-do it bud" 0 0; clear
            fi
        done
    fi
   
    if [ "$MENU" == "4" ]; then
        INIT=$(dialog --title "Init Selection" --menu "Choose your prefered init: " 12 40 3 \
            "init_systemd" "systemd" \
            "init_openrc" "openrc" \
            "init_runit" "runit" 3>&1 1>&2 2>&3 3>&-); clear

        if [ -n "$INIT" ]; then
            dialog --title "Mirrors" --infobox "Finding fast mirrors for your location, hang on..." 0 0
            if refresh_mirrors; then
                MIRRORS_OK=true
                dialog --title "Mirrors" --msgbox "Mirrors updated!" 0 0; clear
            else
                MIRRORS_OK=false
                dialog --title "Uh oh.." --msgbox "Mirror refresh failed, will use the default mirrorlist at install time." 0 0; clear
            fi
        fi
    fi
   
    if [ "$MENU" == "5" ]; then
        DE=$(dialog --title "DE Selection" --menu "Choose your prefered DE: " 12 40 2 \
            "de_kde" "KDE Plasma" \
            "de_xfce" "XFCE4" 3>&1 1>&2 2>&3 3>&-); clear
    fi
   
    if [ "$MENU" == "6" ]; then

        MISSING=""
        [ -z "${USER_:-}" ] && MISSING="${MISSING}\n - User Account"
        [ -z "${HOST:-}" ] && MISSING="${MISSING}\n - Hostname"
        [ -z "${ROOT:-}" ] && MISSING="${MISSING}\n - Root Password"
        [ -z "${INIT:-}" ] && MISSING="${MISSING}\n - Init Selection"
        [ -z "${DE:-}" ] && MISSING="${MISSING}\n - DE selection"

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
      
        if [ $STATUS -ne 0 ]; then
            echo "You stopped the Installation Process"
            echo "PS: we dont save anything so you gotta do evreything again :("
            break
        else
            DE_PKGS=""
            if [ "$DE" == "de_kde" ]; then
                DE_PKGS="plasma-desktop sddm konsole dolphin"
            elif [ "$DE" == "de_xfce" ]; then
                DE_PKGS="xfce4 xfce4-goodies lightdm lightdm-gtk-greeter"
            fi

            TIMEZONE=$(curl -s https://ipinfo.io/timezone)
            if [ -z "$TIMEZONE" ] || [ ! -e "/usr/share/zoneinfo/$TIMEZONE" ]; then
                TIMEZONE="UTC"
            fi

            INIT_OK=true

            # systemd
            if [ "$INIT" == "init_systemd" ]; then
                pacstrap -K /mnt base linux linux-firmware networkmanager grub efibootmgr sudo $DE_PKGS || INIT_OK=false
                genfstab -U /mnt >> /mnt/etc/fstab
                
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

systemctl enable NetworkManager

if [ "$DE" == "de_kde" ]; then
    systemctl enable sddm
elif [ "$DE" == "de_xfce" ]; then
    systemctl enable lightdm
fi
EOF
                [ $? -ne 0 ] && INIT_OK=false
            fi

            # openrc
            if [ "$INIT" == "init_openrc" ]; then
                pacstrap -K /mnt base linux linux-firmware grub efibootmgr sudo git base-devel $DE_PKGS || INIT_OK=false
                genfstab -U /mnt >> /mnt/etc/fstab

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
useradd -m -G wheel builduser
echo "builduser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builduser-temp

su - builduser -c '
    git clone https://aur.archlinux.org/paru-bin.git /tmp/paru-bin &&
    cd /tmp/paru-bin &&
    makepkg -si --noconfirm
' || { echo "AUR_HELPER_FAILED"; exit 1; }

su - builduser -c 'paru -S --noconfirm openrc openrc-systemdcompat networkmanager-openrc' || { echo "OPENRC_INSTALL_FAILED"; exit 1; }

rm -f /etc/sudoers.d/builduser-temp
userdel -r builduser

mkinitcpio -P

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || grub-install /dev/sda
grub-mkconfig -o /boot/grub/grub.cfg

rc-update add NetworkManager default

if [ "$DE" == "de_kde" ]; then
    rc-update add sddm default
elif [ "$DE" == "de_xfce" ]; then
    rc-update add lightdm default
fi
EOF
                [ $? -ne 0 ] && INIT_OK=false
            fi
            
            # runit
            if [ "$INIT" == "init_runit" ]; then
                pacstrap -K /mnt base linux linux-firmware grub efibootmgr sudo git base-devel networkmanager $DE_PKGS || INIT_OK=false
                genfstab -U /mnt >> /mnt/etc/fstab

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

useradd -m -G wheel builduser
echo "builduser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builduser-temp

su - builduser -c '
    git clone https://aur.archlinux.org/paru-bin.git /tmp/paru-bin &&
    cd /tmp/paru-bin &&
    makepkg -si --noconfirm
' || { echo "AUR_HELPER_FAILED"; exit 1; }

su - builduser -c 'paru -S --noconfirm runit' || { echo "RUNIT_INSTALL_FAILED"; exit 1; }

rm -f /etc/sudoers.d/builduser-temp
userdel -r builduser

mkinitcpio -P

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || grub-install /dev/sda
grub-mkconfig -o /boot/grub/grub.cfg

mkdir -p /etc/runit/sv/NetworkManager
cat <<SVEOF > /etc/runit/sv/NetworkManager/run
#!/bin/sh
exec /usr/bin/NetworkManager --no-daemon
SVEOF
chmod +x /etc/runit/sv/NetworkManager/run
mkdir -p /etc/runit/runsvdir/default/
ln -sf /etc/runit/sv/NetworkManager /etc/runit/runsvdir/default/

if [ "$DE" == "de_kde" ]; then
    mkdir -p /etc/runit/sv/sddm
    cat <<SVEOF > /etc/runit/sv/sddm/run
#!/bin/sh
exec sddm
SVEOF
    chmod +x /etc/runit/sv/sddm/run
    ln -sf /etc/runit/sv/sddm /etc/runit/runsvdir/default/
elif [ "$DE" == "de_xfce" ]; then
    mkdir -p /etc/runit/sv/lightdm
    cat <<SVEOF > /etc/runit/sv/lightdm/run
#!/bin/sh
exec lightdm
SVEOF
    chmod +x /etc/runit/sv/lightdm/run
    ln -sf /etc/runit/sv/lightdm /etc/runit/runsvdir/default/
fi
EOF
                [ $? -ne 0 ] && INIT_OK=false
            fi

            if [ "$INIT_OK" == "false" ]; then
                dialog --title "Uh oh.." --msgbox "SOMETHING failed while installing, idk man" 0 0; clear
            else
                dialog --title "All done!" --msgbox "You installed! You can reboot the system." 0 0; clear
            fi
        fi
    fi
        
done
