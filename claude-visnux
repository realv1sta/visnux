#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TARGET_DIR="/mnt"
HOSTNAME=""
ROOT_PASS=""
USERNAME=""
USER_PASS=""
INIT_SYSTEM="systemd"
DESKTOP_ENV="none"
DEPLOY_MODE="imperative"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    exit 1
fi

log_info "Checking prerequisites..."
for tool in dialog pacstrap arch-chroot genfstab grub-install; do
    if ! command -v "$tool" &>/dev/null; then
        log_error "$tool not found. Please ensure you're running this from archiso"
        exit 1
    fi
done
log_success "All prerequisites found"

show_menu() {
    local choice
    while true; do
        echo ""
        echo "========================================"
        echo "    VISNUX LINUX INSTALLER"
        echo "========================================"
        echo ""
        echo "Current Configuration:"
        echo "  Hostname:      ${HOSTNAME:-Not Set}"
        echo "  Root Password: ${ROOT_PASS:+Configured}${ROOT_PASS:-Not Set}"
        echo "  Username:      ${USERNAME:-Not Set}"
        echo "  Init System:   $INIT_SYSTEM"
        echo "  Desktop:       $DESKTOP_ENV"
        echo "  Deploy Mode:   $DEPLOY_MODE"
        echo ""
        echo "1) Set Hostname"
        echo "2) Set Root Password"
        echo "3) Create User Account"
        echo "4) Select Init System"
        echo "5) Select Desktop Environment"
        echo "6) Select Deployment Mode"
        echo "7) Install System"
        echo "8) Exit"
        echo ""
        read -p "Choose option: " choice

        case "$choice" in
            1)
                read -p "Enter hostname: " HOSTNAME
                ;;
            2)
                read -sp "Enter root password: " ROOT_PASS
                echo ""
                read -sp "Confirm root password: " ROOT_PASS_CONFIRM
                echo ""
                if [[ "$ROOT_PASS" != "$ROOT_PASS_CONFIRM" ]]; then
                    log_error "Passwords do not match"
                    ROOT_PASS=""
                else
                    log_success "Root password set"
                fi
                ;;
            3)
                read -p "Enter username: " USERNAME
                read -sp "Enter password: " USER_PASS
                echo ""
                read -sp "Confirm password: " USER_PASS_CONFIRM
                echo ""
                if [[ "$USER_PASS" != "$USER_PASS_CONFIRM" ]]; then
                    log_error "Passwords do not match"
                    USERNAME=""
                    USER_PASS=""
                else
                    log_success "User account configured"
                fi
                ;;
            4)
                echo ""
                echo "Select Init System:"
                echo "1) systemd (default)"
                echo "2) openrc"
                echo "3) runit"
                echo "4) dinit"
                echo ""
                read -p "Choose (1-4): " init_choice
                case "$init_choice" in
                    1) INIT_SYSTEM="systemd" ;;
                    2) INIT_SYSTEM="openrc" ;;
                    3) INIT_SYSTEM="runit" ;;
                    4) INIT_SYSTEM="dinit" ;;
                    *) log_warn "Invalid choice, keeping $INIT_SYSTEM" ;;
                esac
                log_info "Init system set to: $INIT_SYSTEM"
                ;;
            5)
                echo ""
                echo "Select Desktop Environment:"
                echo "1) none (minimal CLI)"
                echo "2) xfce"
                echo "3) kde"
                echo "4) gnome"
                echo ""
                read -p "Choose (1-4): " de_choice
                case "$de_choice" in
                    1) DESKTOP_ENV="none" ;;
                    2) DESKTOP_ENV="xfce" ;;
                    3) DESKTOP_ENV="kde" ;;
                    4) DESKTOP_ENV="gnome" ;;
                    *) log_warn "Invalid choice, keeping $DESKTOP_ENV" ;;
                esac
                log_info "Desktop environment set to: $DESKTOP_ENV"
                ;;
            6)
                echo ""
                echo "Select Deployment Mode:"
                echo "1) imperative (standard install)"
                echo "2) declarative (generates config)"
                echo ""
                read -p "Choose (1-2): " mode_choice
                case "$mode_choice" in
                    1) DEPLOY_MODE="imperative" ;;
                    2) DEPLOY_MODE="declarative" ;;
                    *) log_warn "Invalid choice, keeping $DEPLOY_MODE" ;;
                esac
                log_info "Deployment mode set to: $DEPLOY_MODE"
                ;;
            7)
                if [[ -z "$HOSTNAME" || -z "$ROOT_PASS" || -z "$USERNAME" ]]; then
                    log_error "Missing required configuration: Hostname, Root Password, or Username"
                    continue
                fi

                if ! mountpoint -q "$TARGET_DIR"; then
                    log_error "Nothing mounted at $TARGET_DIR"
                    log_info "Please mount your root partition first"
                    continue
                fi

                echo ""
                echo "========================================"
                echo "    INSTALLATION SUMMARY"
                echo "========================================"
                echo "Target:        $TARGET_DIR"
                echo "Hostname:      $HOSTNAME"
                echo "Username:      $USERNAME"
                echo "Init System:   $INIT_SYSTEM"
                echo "Desktop:       $DESKTOP_ENV"
                echo "Deploy Mode:   $DEPLOY_MODE"
                echo "========================================"
                echo ""
                read -p "Proceed with installation? (yes/no): " confirm

                if [[ "$confirm" == "yes" ]]; then
                    perform_installation
                    return 0
                else
                    log_info "Installation cancelled"
                fi
                ;;
            8)
                log_info "Exiting installer"
                exit 0
                ;;
            *)
                log_error "Invalid option"
                ;;
        esac
    done
}

perform_installation() {
    log_info "Starting Visnux installation..."
    echo ""

    local is_uefi=false
    if [[ -d "/sys/firmware/efi/efivars" ]]; then
        is_uefi=true
        log_info "UEFI system detected"
    else
        log_info "BIOS/MBR system detected"
    fi

    log_info "Configuring package repositories..."
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        log_info "Using standard Arch repositories"
    else
        log_warn "Non-systemd init selected ($INIT_SYSTEM)"
        log_warn "Make sure you have artix repos configured or this will fail"
        log_warn "Continuing anyway, but be aware..."
    fi

    log_info "Syncing package database..."
    if ! pacman -Sy --noconfirm; then
        log_error "Failed to sync package database"
        return 1
    fi
    log_success "Package database updated"

    local init_packages=""
    case "$INIT_SYSTEM" in
        systemd)
            init_packages="systemd systemd-sysvcompat networkmanager"
            ;;
        openrc)
            log_warn "openrc requires artix repos - may fail on arch iso"
            init_packages="openrc openrc-systemd-compat networkmanager-openrc"
            ;;
        runit)
            log_warn "runit requires artix repos - may fail on arch iso"
            init_packages="runit runit-systemd-compat networkmanager-runit"
            ;;
        dinit)
            log_warn "dinit requires artix repos - may fail on arch iso"
            init_packages="dinit dinit-systemd-compat networkmanager-dinit"
            ;;
    esac

    local de_packages=""
    local dm_service=""
    case "$DESKTOP_ENV" in
        xfce)
            de_packages="xorg lightdm lightdm-gtk-greeter xfce4 xfce4-goodies"
            dm_service="lightdm"
            [[ "$INIT_SYSTEM" != "systemd" ]] && de_packages="$de_packages lightdm-$INIT_SYSTEM"
            ;;
        kde)
            de_packages="xorg sddm plasma kde-applications"
            dm_service="sddm"
            [[ "$INIT_SYSTEM" != "systemd" ]] && de_packages="$de_packages sddm-$INIT_SYSTEM"
            ;;
        gnome)
            de_packages="xorg gdm gnome gnome-extra"
            dm_service="gdm"
            [[ "$INIT_SYSTEM" != "systemd" ]] && de_packages="$de_packages gdm-$INIT_SYSTEM"
            ;;
    esac

    log_info "Installing base system and packages..."
    log_info "This may take several minutes..."
    if ! pacstrap -K "$TARGET_DIR" base linux linux-firmware base-devel grub efibootmgr fastfetch $init_packages $de_packages; then
        log_error "pacstrap failed - installation aborted"
        return 1
    fi
    log_success "Base system installed"

    log_info "Generating fstab..."
    if ! genfstab -U "$TARGET_DIR" >> "$TARGET_DIR/etc/fstab"; then
        log_error "genfstab failed"
        return 1
    fi
    log_success "fstab generated"
    log_warn "VERIFY fstab is correct: cat $TARGET_DIR/etc/fstab"

    if [[ "$DEPLOY_MODE" == "declarative" ]]; then
        log_info "Creating declarative spec file..."
        cat > "$TARGET_DIR/etc/visnux.spec" <<EOF
SYSTEM_HOSTNAME="$HOSTNAME"
SYSTEM_INIT="$INIT_SYSTEM"
DESKTOP_ENV="$DESKTOP_ENV"
PRIMARY_USER="$USERNAME"
ENABLE_NETWORK=true
ENABLE_SUDO=true
EOF

        cat > "$TARGET_DIR/usr/local/bin/visnux-rebuild" <<'SCRIPT'
#!/bin/bash
source /etc/visnux.spec
echo "$SYSTEM_HOSTNAME" > /etc/hostname
if [ "$ENABLE_SUDO" = true ]; then
    sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
fi
echo "System synchronized with /etc/visnux.spec"
SCRIPT
        chmod +x "$TARGET_DIR/usr/local/bin/visnux-rebuild"
        log_success "Declarative spec created"
    fi

    log_info "Applying system configuration..."

    echo "$HOSTNAME" > "$TARGET_DIR/etc/hostname"
    cat > "$TARGET_DIR/etc/hosts" <<EOF
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
127.0.0.1 localhost
::1 localhost
EOF

    cat > "$TARGET_DIR/etc/os-release" <<EOF
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

    cat > "$TARGET_DIR/etc/issue" <<EOF
Visnux Linux (\l)
EOF
    cp "$TARGET_DIR/etc/issue" "$TARGET_DIR/etc/motd"

    log_info "Setting up fastfetch..."
    mkdir -p "$TARGET_DIR/etc/fastfetch"

    cat > "$TARGET_DIR/etc/fastfetch/visnux.ascii" <<'ASCII'
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
_ jKKN
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
ASCII

    cat > "$TARGET_DIR/etc/fastfetch/config.jsonc" <<'CONFIG'
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
CONFIG

    log_success "Fastfetch configured"

    log_info "Setting root password..."
    echo "root:$ROOT_PASS" | arch-chroot "$TARGET_DIR" chpasswd
    log_success "Root password set"

    log_info "Creating user account..."
    arch-chroot "$TARGET_DIR" useradd -m -G wheel -s /bin/bash "$USERNAME"
    echo "$USERNAME:$USER_PASS" | arch-chroot "$TARGET_DIR" chpasswd
    log_success "User account created"

    log_info "Configuring sudo access..."
    if arch-chroot "$TARGET_DIR" grep -q "^# %wheel ALL=(ALL:ALL) ALL" /etc/sudoers; then
        arch-chroot "$TARGET_DIR" sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
        log_success "Sudo configured for wheel group"
    else
        log_warn "Could not find sudo line to uncomment - you may need to configure manually"
    fi

    log_info "Configuring services for $INIT_SYSTEM..."

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        arch-chroot "$TARGET_DIR" systemctl enable NetworkManager
        [[ -n "$dm_service" ]] && arch-chroot "$TARGET_DIR" systemctl enable "$dm_service"
        log_success "systemd services enabled"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        arch-chroot "$TARGET_DIR" rc-update add NetworkManager default
        [[ -n "$dm_service" ]] && arch-chroot "$TARGET_DIR" rc-update add "$dm_service" default
        log_success "OpenRC services enabled"
    elif [[ "$INIT_SYSTEM" == "runit" ]]; then
        arch-chroot "$TARGET_DIR" ln -sf /etc/runit/sv/NetworkManager /etc/runit/runsvdir/default/
        [[ -n "$dm_service" ]] && arch-chroot "$TARGET_DIR" ln -sf "/etc/runit/sv/$dm_service" /etc/runit/runsvdir/default/
        log_success "Runit services configured"
    elif [[ "$INIT_SYSTEM" == "dinit" ]]; then
        arch-chroot "$TARGET_DIR" dinitctl enable NetworkManager
        [[ -n "$dm_service" ]] && arch-chroot "$TARGET_DIR" dinitctl enable "$dm_service"
        log_success "Dinit services enabled"
    fi

    log_info "Installing bootloader..."

    if [[ "$is_uefi" == true ]]; then
        log_info "Installing GRUB for UEFI..."
        if ! arch-chroot "$TARGET_DIR" grub-install --target=x86_64-efi --efi-directory=/mnt/boot --bootloader-id=Visnux; then
            log_error "GRUB UEFI installation failed"
            return 1
        fi
    else
        log_info "Installing GRUB for BIOS..."
        local target_disk
        target_disk=$(lsblk -ndo pkname "$(df "$TARGET_DIR" | tail -1 | awk '{print $1}')")
        if [[ -z "$target_disk" ]]; then
            log_error "Could not determine target disk - please check your setup"
            log_error "Run: df $TARGET_DIR"
            return 1
        fi
        log_info "Installing GRUB to /dev/$target_disk"
        if ! arch-chroot "$TARGET_DIR" grub-install "/dev/$target_disk"; then
            log_error "GRUB BIOS installation failed"
            return 1
        fi
    fi

    if ! arch-chroot "$TARGET_DIR" grub-mkconfig -o /mnt/boot/grub/grub.cfg; then
        log_error "GRUB configuration generation failed"
        return 1
    fi
    log_success "Bootloader installed and configured"
    echo ""
    echo "========================================"
    echo "    INSTALLATION COMPLETE!"
    echo "========================================"
    echo ""
    log_success "Visnux has been successfully installed"
    log_info "You can now reboot into your new system"
    log_info "After reboot, log in and run: fastfetch"
    echo "remember to install and configure mirrors,pipewire since theyre not configured yet (install it urself)"
}

log_info "Welcome to Visnux Linux Installer"
log_warn "Make sure you have partitioned and mounted your drives to /mnt"
echo ""
show_menu
