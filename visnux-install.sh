# VISNUX INSTALL SCRIPT <3

#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "Please run this installer as root."
    exit 1
fi

if ! command -v dialog &> /dev/null; then
    echo "'dialog' is required but not installed."
    read -p "Would you like to install it now via pacman? (y/N): " choice
    case "$choice" in 
        [yY][eE][sS]|[yY])
            pacman -Sy --noconfirm dialog || { echo "Failed to install dialog. Exiting."; exit 1; }
            ;;
        *)
            echo "Installation aborted. Please install 'dialog' manually using: sudo pacman -S dialog"
            exit 1
            ;;
    esac
fi

TARGET_DIR="/mnt"

HOSTNAME=""
ROOT_PASS=""
USERNAME=""
USER_PASS=""
INIT_SYSTEM="systemd"
DESKTOP_ENV="none"
DEPLOY_MODE="imperative"

dialog --title "Welcome to Visnux!" \
       --msgbox "Welcome to the Visnux Linux Installer.\n\n Before you do anything, partition the drives before installing. THANKS -v1sta" 11 65

while true; do
    STATUS_HOST="${HOSTNAME:-Not Set}"
    STATUS_ROOT="${ROOT_PASS:+Configured}"
    STATUS_ROOT="${STATUS_ROOT:-Not Set}"
    STATUS_USER="${USERNAME:-Not Set}"

    MENU=$(dialog --title "Visnux Configuration Menu" \
                  --menu "Current Configuration:\n- Hostname: $STATUS_HOST | User: $STATUS_USER\n- Init: $INIT_SYSTEM | Desktop: $DESKTOP_ENV | Mode: $DEPLOY_MODE" 19 65 7 \
                  1 "Set Hostname" \
                  2 "Set Root Password" \
                  3 "Create User Account" \
                  4 "Select Init System" \
                  5 "Select Desktop Environment" \
                  6 "Select Deployment Mode" \
                  7 "Install System" \
                  3>&1 1>&2 2>&3 3>&-)

    if [ $? -ne 0 ]; then
        clear
        echo "Installation cancelled."
        exit 0
    fi

    case "$MENU" in
        1)
            INPUT=$(dialog --title "Hostname" --inputbox "Enter target hostname:" 8 50 "$HOSTNAME" 3>&1 1>&2 2>&3 3>&-)
            if [ $? -eq 0 ] && [[ -n "$INPUT" ]]; then HOSTNAME="$INPUT"; fi
            ;;

        2)
            PASS1=$(dialog --title "Root Password" --passwordbox "Enter Root Password:" 8 50 3>&1 1>&2 2>&3 3>&-)
            [ $? -ne 0 ] && continue
            PASS2=$(dialog --title "Root Password" --passwordbox "Confirm Root Password:" 8 50 3>&1 1>&2 2>&3 3>&-)
            [ $? -ne 0 ] && continue
            if [ "$PASS1" == "$PASS2" ] && [ -n "$PASS1" ]; then
                ROOT_PASS="$PASS1"
            else
                dialog --title "Error" --msgbox "Passwords do not match or were empty!" 6 45
            fi
            ;;

        3)
            NEW_USER=$(dialog --title "User Account" --inputbox "Enter username:" 8 50 "$USERNAME" 3>&1 1>&2 2>&3 3>&-)
            [ $? -ne 0 ] && continue
            UPASS1=$(dialog --title "User Password" --passwordbox "Enter password for $NEW_USER:" 8 50 3>&1 1>&2 2>&3 3>&-)
            [ $? -ne 0 ] && continue
            UPASS2=$(dialog --title "User Password" --passwordbox "Confirm password:" 8 50 3>&1 1>&2 2>&3 3>&-)
            [ $? -ne 0 ] && continue
            if [ "$UPASS1" == "$UPASS2" ] && [ -n "$NEW_USER" ]; then
                USERNAME="$NEW_USER"
                USER_PASS="$UPASS1"
            else
                dialog --title "Error" --msgbox "Invalid input or mismatched passwords!" 6 45
            fi
            ;;

        4)
            INIT_CHOICE=$(dialog --title "Init Freedom Selection" \
                                 --radiolist "Choose an init system for Visnux:" 13 55 4 \
                                 "systemd" "Standard Systemd" ON \
                                 "openrc"  "OpenRC init" OFF \
                                 "runit"   "Runit process monitor" OFF \
                                 "dinit"   "Dinit service manager" OFF \
                                 3>&1 1>&2 2>&3 3>&-)
            if [ $? -eq 0 ] && [ -n "$INIT_CHOICE" ]; then
                INIT_SYSTEM="$INIT_CHOICE"
            fi
            ;;

        5)
            DE_CHOICE=$(dialog --title "Desktop Environment" \
                               --radiolist "Choose a desktop environment for Visnux:" 13 55 4 \
                               "none"  "Minimal CLI" ON \
                               "xfce"  "XFCE4 Desktop" OFF \
                               "kde"   "KDE Plasma" OFF \
                               "gnome" "GNOME Desktop" OFF \
                               3>&1 1>&2 2>&3 3>&-)
            if [ $? -eq 0 ] && [ -n "$DE_CHOICE" ]; then
                DESKTOP_ENV="$DE_CHOICE"
            fi
            ;;

        6)
            MODE_CHOICE=$(dialog --title "Deployment Strategy" \
                                 --radiolist "Select system deployment style:" 12 60 2 \
                                 "imperative" "Standard Arch/Artix installation" ON \
                                 "declarative" "Generates a reproducible setup spec script" OFF \
                                 3>&1 1>&2 2>&3 3>&-)
            if [ $? -eq 0 ] && [ -n "$MODE_CHOICE" ]; then
                DEPLOY_MODE="$MODE_CHOICE"
            fi
            ;;

        7)
            if [ -z "$HOSTNAME" ] || [ -z "$ROOT_PASS" ] || [ -z "$USERNAME" ]; then
                dialog --title "Missing Configuration" --msgbox "Please configure Hostname, Root Password, and User Account first!" 7 50
                continue
            fi

            if ! mountpoint -q "$TARGET_DIR"; then
                dialog --title "Error" --msgbox "Nothing mounted at $TARGET_DIR! Mount root partition first." 7 50
                continue
            fi

            IS_UEFI=false
            [ -d "/sys/firmware/efi/efivars" ] && IS_UEFI=true

            dialog --title "Confirm Installation" \
                   --yesno "Ready to install Visnux?\n\n- Init System: $INIT_SYSTEM\n- Desktop: $DESKTOP_ENV\n- Mode: $DEPLOY_MODE\n- Target: $TARGET_DIR" 11 55
            [ $? -ne 0 ] && continue

            (
                echo "10"; echo "XXX"; echo "Configuring Repositories for $INIT_SYSTEM..."; echo "XXX"

                if [ "$INIT_SYSTEM" == "systemd" ]; then
                    cat <<EOF > /etc/pacman.d/mirrorlist
Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch
EOF
                else
                    cat <<EOF > /etc/pacman.d/mirrorlist
Server = https://mirror.artixlinux.org/repos/\$repo/os/\$arch
Server = https://artix.dingo.kiwi/repos/\$repo/os/\$arch
EOF
                    cat <<EOF > /etc/pacman.conf
[options]
HoldPkg     = pacman glibc
Architecture = auto
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

[system]
Include = /etc/pacman.d/mirrorlist

[world]
Include = /etc/pacman.d/mirrorlist

[galaxy]
Include = /etc/pacman.d/mirrorlist

[$INIT_SYSTEM]
Include = /etc/pacman.d/mirrorlist
EOF
                fi

                pacman -Sy --noconfirm > /dev/null 2>&1

                INIT_PACKAGES=""
                case "$INIT_SYSTEM" in
                    systemd) INIT_PACKAGES="systemd systemd-sysvcompat networkmanager" ;;
                    openrc)  INIT_PACKAGES="openrc openrc-systemd-compat networkmanager-openrc" ;;
                    runit)   INIT_PACKAGES="runit runit-systemd-compat networkmanager-runit" ;;
                    dinit)   INIT_PACKAGES="dinit dinit-systemd-compat networkmanager-dinit" ;;
                esac

                DE_PACKAGES=""
                DM_SERVICE=""
                case "$DESKTOP_ENV" in
                    xfce)
                        DE_PACKAGES="xorg lightdm lightdm-gtk-greeter xfce4 xfce4-goodies"
                        DM_SERVICE="lightdm"
                        [ "$INIT_SYSTEM" != "systemd" ] && DE_PACKAGES="$DE_PACKAGES lightdm-$INIT_SYSTEM"
                        ;;
                    kde)
                        DE_PACKAGES="xorg sddm plasma kde-applications"
                        DM_SERVICE="sddm"
                        [ "$INIT_SYSTEM" != "systemd" ] && DE_PACKAGES="$DE_PACKAGES sddm-$INIT_SYSTEM"
                        ;;
                    gnome)
                        DE_PACKAGES="xorg gdm gnome gnome-extra"
                        DM_SERVICE="gdm"
                        [ "$INIT_SYSTEM" != "systemd" ] && DE_PACKAGES="$DE_PACKAGES gdm-$INIT_SYSTEM"
                        ;;
                esac

                echo "25"; echo "XXX"; echo "Installing Base System, Fastfetch & Packages ($INIT_SYSTEM / $DESKTOP_ENV)..."; echo "XXX"
                pacstrap -K "$TARGET_DIR" base linux linux-firmware base-devel grub efibootmgr fastfetch $INIT_PACKAGES $DE_PACKAGES > /dev/null 2>&1

                cp /etc/pacman.conf "$TARGET_DIR/etc/pacman.conf"
                cp /etc/pacman.d/mirrorlist "$TARGET_DIR/etc/pacman.d/mirrorlist"

                echo "45"; echo "XXX"; echo "Generating fstab..."; echo "XXX"
                genfstab -U "$TARGET_DIR" >> "$TARGET_DIR/etc/fstab"

                if [ "$DEPLOY_MODE" == "declarative" ]; then
                    echo "55"; echo "XXX"; echo "Generating Declarative Spec (/etc/visnux.spec)..."; echo "XXX"
                    
                    cat <<EOF > "$TARGET_DIR/etc/visnux.spec"
SYSTEM_HOSTNAME="$HOSTNAME"
SYSTEM_INIT="$INIT_SYSTEM"
DESKTOP_ENV="$DESKTOP_ENV"
PRIMARY_USER="$USERNAME"
ENABLE_NETWORK=true
ENABLE_SUDO=true
EOF

                    cat <<'EOF' > "$TARGET_DIR/usr/local/bin/visnux-rebuild"
#!/bin/bash
source /etc/visnux.spec
echo "$SYSTEM_HOSTNAME" > /etc/hostname
if [ "$ENABLE_SUDO" = true ]; then
    sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
fi
echo "System synchronized with /etc/visnux.spec"
EOF
                    chmod +x "$TARGET_DIR/usr/local/bin/visnux-rebuild"
                fi

                echo "65"; echo "XXX"; echo "Applying System Settings & Fastfetch Branding..."; echo "XXX"
                echo "$HOSTNAME" > "$TARGET_DIR/etc/hostname"
                cat <<EOF > "$TARGET_DIR/etc/hosts"
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
127.0.0.1   localhost
::1         localhost
EOF

                cat <<EOF > "$TARGET_DIR/etc/os-release"
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

                
                cat <<EOF > "$TARGET_DIR/etc/issue"
Visnux Linux (\l)

EOF
                cp "$TARGET_DIR/etc/issue" "$TARGET_DIR/etc/motd"

                # Configure Fastfetch Custom ASCII Art
                mkdir -p "$TARGET_DIR/etc/fastfetch"
                cat <<'EOF' > "$TARGET_DIR/etc/fastfetch/visnux.ascii"
                                __,,,,,___
                            _,g#KKKKKKKKKKKm~_
                          ,#KKKKKKKKKKKKKKKKKKm_
                        _;KKKKKKKKKKKKKKKKKKKKKKp
                        jKKKKKKKKKKKKKKKKKKKKKKKBp
                        KKKKKKKKKKKKKKKKKKKKKKKKKK_
                       ]KKKKKKKKKKKKKKKKKKKKKKKKKKL
                       )KKKKKKKKKKKKKKKKKKKKKKKKKKP
                       _0KKKKKKKKKKKKKKKKKKKKKKKKK__,,,,_
                        `KKKKKKKKKKKKKKKKKKKKKKKKNKKKKKKKKm_
                     ,g#KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKp
                  _#KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK
                 _0KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKP
                 }KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKP_
                 1KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKwwp__
                  0KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK0Kp
                   TKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKm
                   __][KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK
                 _aKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKP
                _#KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK0M
                )KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKM`
                _0KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK0KKMl
                  YBKKKKKKKKKKKKKKKKKBMMMMMMMMMMMf"l`
                    ?KKKBK0KKBKKM"l` }KKP
                       _             jKKN
                                     jKKN
                                     jKKK
                                     ]KKK_
                                     ]KKKP
                                     ]KKKP
                                     ]KKK[
                                     ]KKKN
                                     ]KKKK_
                                      KKKK_
                                      KKKKP
                                      ff"""
EOF

                cat <<'EOF' > "$TARGET_DIR/etc/fastfetch/config.jsonc"
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": {
    "type": "file",
    "source": "/etc/fastfetch/visnux.ascii",
    "color": {
      "1": "green"
    }
  },
  "modules": [
    "title",
    "separator",
    "os",
    "host",
    "kernel",
    "uptime",
    "packages",
    "shell",
    "wm",
    "terminal",
    "cpu",
    "gpu",
    "memory",
    "break",
    "colors"
  ]
}
EOF

                echo "root:$ROOT_PASS" | arch-chroot "$TARGET_DIR" chpasswd
                arch-chroot "$TARGET_DIR" useradd -m -G wheel -s /bin/bash "$USERNAME"
                echo "$USERNAME:$USER_PASS" | arch-chroot "$TARGET_DIR" chpasswd
                sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' "$TARGET_DIR/etc/sudoers"

                echo "85"; echo "XXX"; echo "Configuring $INIT_SYSTEM Services & Bootloader..."; echo "XXX"
                
                if [ "$INIT_SYSTEM" == "systemd" ]; then
                    arch-chroot "$TARGET_DIR" systemctl enable NetworkManager > /dev/null 2>&1
                    [ -n "$DM_SERVICE" ] && arch-chroot "$TARGET_DIR" systemctl enable "$DM_SERVICE" > /dev/null 2>&1
                elif [ "$INIT_SYSTEM" == "openrc" ]; then
                    arch-chroot "$TARGET_DIR" rc-update add NetworkManager default > /dev/null 2>&1
                    [ -n "$DM_SERVICE" ] && arch-chroot "$TARGET_DIR" rc-update add "$DM_SERVICE" default > /dev/null 2>&1
                elif [ "$INIT_SYSTEM" == "runit" ]; then
                    arch-chroot "$TARGET_DIR" ln -s /etc/runit/sv/NetworkManager /etc/runit/runsvdir/default/ > /dev/null 2>&1
                    [ -n "$DM_SERVICE" ] && arch-chroot "$TARGET_DIR" ln -s "/etc/runit/sv/$DM_SERVICE" /etc/runit/runsvdir/default/ > /dev/null 2>&1
                elif [ "$INIT_SYSTEM" == "dinit" ]; then
                    arch-chroot "$TARGET_DIR" dinitctl enable NetworkManager > /dev/null 2>&1
                    [ -n "$DM_SERVICE" ] && arch-chroot "$TARGET_DIR" dinitctl enable "$DM_SERVICE" > /dev/null 2>&1
                fi

                if [ "$IS_UEFI" = true ]; then
                    arch-chroot "$TARGET_DIR" grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Visnux > /dev/null 2>&1
                else
                    TARGET_DISK=$(df "$TARGET_DIR" | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
                    arch-chroot "$TARGET_DIR" grub-install "$TARGET_DISK" > /dev/null 2>&1
                fi
                arch-chroot "$TARGET_DIR" grub-mkconfig -o /boot/grub/grub.cfg > /dev/null 2>&1

                echo "100"; echo "XXX"; echo "Installation Complete!"; echo "XXX"
                sleep 1
            ) | dialog --title "Installing Visnux Linux" --gauge "Running installation..." 10 65 0

            dialog --title "Success" --msgbox "Visnux Linux installed successfully!" 7 60
            clear
            break
            ;;
    esac
done
