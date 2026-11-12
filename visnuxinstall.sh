#!/bin/bash
set -u
set -o pipefail

USER_=""
PASSWORD=""
HOST=""
ROOT=""
INIT=""
DE=""
WIFI_SSID=""
WIFI_PASS=""
BOOTMODE_CHOICE=""
GPU_CHOICE=""
GPU_PKGS=""
GPU_LABEL=""
BOOTLOADER="grub"
BL_PKGS=""
LOGFILE="/tmp/visnux_install.log"

check_mount() {
    mountpoint -q /mnt
}

show_error_log() {
    grep -n -iE 'error|failed|fatal|not found|conflict|no space' "$LOGFILE" | tail -60 > /tmp/visnux_errors.log
    if [ -s /tmp/visnux_errors.log ]; then
        dialog --title "Installation Failed - Key Errors" --textbox /tmp/visnux_errors.log 20 75; clear
    fi
    dialog --title "Installation Failed - Error Log" --textbox "$LOGFILE" 20 75; clear
}

fix_keyrings_and_time() {
    echo "=== Synchronizing System Time & Fixing Keyrings ===" >> "$LOGFILE"
    timedatectl set-ntp true 2>/dev/null || true
    pacman-key --init 2>&1 | tee -a "$LOGFILE" || true
    pacman-key --populate archlinux 2>&1 | tee -a "$LOGFILE" || true
}


network_preflight_check() {
    local ok=true
    local msg=""

    if ! curl -s --max-time 5 -o /dev/null https://1.1.1.1; then
        msg="${msg}\n - No raw network connectivity (couldn't reach 1.1.1.1). Connect Wi-Fi (iwctl) or ethernet (dhcpcd) first."
        ok=false
    elif ! curl -s --max-time 5 -o /dev/null https://archlinux.org; then
        msg="${msg}\n - Network is up but DNS resolution is failing. Check /etc/resolv.conf on this live session."
        ok=false
    fi

    local now_year
    now_year=$(date +%Y)
    if [ "$now_year" -lt 2024 ]; then
        msg="${msg}\n - System clock looks wrong (year $now_year). This breaks HTTPS certificate validation and can look exactly like a network failure. Run: timedatectl set-ntp true (or set-time manually)."
        ok=false
    fi

    if [ "$ok" == "false" ]; then
        dialog --title "Network Check Failed" --msgbox "Before installing, fix the following on THIS live session (not the target disk):$msg\n\nThen relaunch the installer." 0 0; clear
        return 1
    fi
    return 0
}

setup_chroot_dns() {
    rm -f /mnt/etc/resolv.conf
    cat <<EOF > /mnt/etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
}

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

    chmod 600 "$conn_file"
    chown root:root "$conn_file" 2>/dev/null || true
}


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

    pacman -Syy --noconfirm >> "$LOGFILE" 2>&1 || true
    pacman -S --noconfirm --needed archlinux-keyring >> "$LOGFILE" 2>&1 || true
    if pacman -Si artix-keyring >/dev/null 2>&1; then
        pacman -S --noconfirm --needed artix-keyring >> "$LOGFILE" 2>&1 || true
    fi
}

bootstrap_keyring() {
    local name="$1"
    local conf="$2"
    local populate="$3"
    local fallback="${4:-}"
    local kr_db=/tmp/keyring-db
    local kr_cache=/tmp/keyring-cache
    local kr_conf=/tmp/keyring.conf
    local pkg=""
    local src

    echo "=== Fetching the current $name ===" | tee -a "$LOGFILE"
    rm -rf "$kr_db" "$kr_cache" "$kr_conf"
    mkdir -p "$kr_db/local" "$kr_cache"

    for src in "$conf" $fallback; do
        [ -n "$pkg" ] && break
        [ -r "$src" ] || continue
        sed 's/^SigLevel.*/SigLevel = Never/' "$src" > "$kr_conf"
        pacman --config "$kr_conf" --dbpath "$kr_db" --cachedir "$kr_cache" -Syw --noconfirm "$name" 2>&1 | tee -a "$LOGFILE" || true
        pkg=$(ls -1t "$kr_cache"/"$name"-[0-9]*.pkg.tar.* 2>/dev/null | grep -v '\.sig$' | head -n 1)
    done

    if [ -z "$pkg" ]; then
        echo "WARNING: could not download the current $name, continuing with the keys already on this system." | tee -a "$LOGFILE"
        rm -rf "$kr_db" "$kr_cache" "$kr_conf"
        return 0
    fi

    if ! pacman -U --noconfirm "$pkg" 2>&1 | tee -a "$LOGFILE"; then
        echo "WARNING: pacman -U failed for $pkg, extracting the keyring files directly." | tee -a "$LOGFILE"
        bsdtar -xf "$pkg" -C / usr/share/pacman/keyrings 2>&1 | tee -a "$LOGFILE" || true
    fi

    pacman-key --populate "$populate" 2>&1 | tee -a "$LOGFILE" || true
    rm -rf "$kr_db" "$kr_cache" "$kr_conf"
}

detect_gpus() {
    GPU_AMD=false
    GPU_INTEL=false
    GPU_NV_OPEN=false
    GPU_NV_OLD=false
    local dev class vendor id
    for dev in /sys/bus/pci/devices/*; do
        [ -r "$dev/class" ] || continue
        class=$(cat "$dev/class" 2>/dev/null)
        case "$class" in
            0x03*) ;;
            *) continue ;;
        esac
        vendor=$(cat "$dev/vendor" 2>/dev/null)
        id=$(cat "$dev/device" 2>/dev/null)
        case "$vendor" in
            0x1002) GPU_AMD=true ;;
            0x8086) GPU_INTEL=true ;;
            0x10de)
                if [ $((${id:-0x0})) -ge $((0x1e00)) ]; then
                    GPU_NV_OPEN=true
                else
                    GPU_NV_OLD=true
                fi
                ;;
        esac
    done
}

resolve_gpu_packages() {
    local list=""
    local names=""
    GPU_LABEL=""
    case "$GPU_CHOICE" in
        amd)
            list="mesa vulkan-radeon"
            GPU_LABEL="AMD (Mesa + Vulkan)"
            ;;
        intel)
            list="mesa vulkan-intel intel-media-driver"
            GPU_LABEL="Intel (Mesa + Vulkan + VA-API)"
            ;;
        nvidia)
            list="nvidia-open nvidia-utils nvidia-settings"
            GPU_LABEL="NVIDIA GTX 16xx / RTX or newer (nvidia-open)"
            ;;
        nouveau)
            list="mesa vulkan-nouveau"
            GPU_LABEL="NVIDIA older cards (open-source Nouveau)"
            ;;
        none)
            list="mesa"
            GPU_LABEL="Generic / VM (Mesa only)"
            ;;
        *)
            detect_gpus
            if [ "$GPU_AMD" == "true" ]; then list="$list mesa vulkan-radeon"; names="$names AMD"; fi
            if [ "$GPU_INTEL" == "true" ]; then list="$list mesa vulkan-intel intel-media-driver"; names="$names Intel"; fi
            if [ "$GPU_NV_OPEN" == "true" ]; then list="$list nvidia-open nvidia-utils nvidia-settings"; names="$names NVIDIA(nvidia-open)"; fi
            if [ "$GPU_NV_OLD" == "true" ]; then list="$list mesa vulkan-nouveau"; names="$names NVIDIA(Nouveau)"; fi
            if [ -z "$list" ]; then
                list="mesa"
                names=" no known GPU found (VM?) - Mesa only"
            fi
            GPU_LABEL="Auto-detected:$names"
            ;;
    esac
    GPU_PKGS=$(echo $list | tr ' ' '\n' | sort -u | tr '\n' ' ')
    GPU_PKGS=${GPU_PKGS% }
}

bootloader_chroot_script() {
    case "$BOOTLOADER" in
        limine)
            cat <<BLEOF
mkdir -p "$EFI_DIR/EFI/limine" "$EFI_DIR/EFI/BOOT"
cp -f /usr/share/limine/BOOTX64.EFI "$EFI_DIR/EFI/limine/BOOTX64.EFI"
if [ \$? -ne 0 ]; then
    echo "FATAL: could not copy the Limine EFI binary. Check that the limine package installed correctly." >&2
    exit 1
fi

cat <<'LIMINECONF' > "$EFI_DIR/EFI/limine/limine.conf"
timeout: 5

/Visnux Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: root=UUID=$ROOT_UUID rw
    module_path: boot():/initramfs-linux.img

/Visnux Linux (fallback initramfs)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: root=UUID=$ROOT_UUID rw
    module_path: boot():/initramfs-linux-fallback.img
LIMINECONF

if [ -f "$EFI_DIR/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
    cat <<'LIMINEWIN' >> "$EFI_DIR/EFI/limine/limine.conf"

/Windows
    protocol: efi
    path: boot():/EFI/Microsoft/Boot/bootmgfw.efi
LIMINEWIN
fi

cp -f "$EFI_DIR/EFI/limine/BOOTX64.EFI" "$EFI_DIR/EFI/BOOT/BOOTX64.EFI" || true
cp -f "$EFI_DIR/EFI/limine/limine.conf" "$EFI_DIR/EFI/BOOT/limine.conf" || true

if [ "$UEFI_NVRAM_OK" = "true" ]; then
    efibootmgr --create --disk "$ESP_DISK" --part "$ESP_PARTNUM" --label "Visnux (Limine)" --loader '\EFI\limine\BOOTX64.EFI' --unicode || echo "WARNING: could not create a firmware boot entry for Limine, relying on the fallback path EFI/BOOT/BOOTX64.EFI." >&2
fi
BLEOF
            ;;
        refind)
            cat <<BLEOF
if [ "$UEFI_NVRAM_OK" = "true" ]; then
    refind-install
else
    refind-install --usedefault "$ESP_DEV"
fi
if [ \$? -ne 0 ]; then
    echo "WARNING: refind-install failed, retrying with --usedefault (fallback path, no firmware boot entry)." >&2
    refind-install --usedefault "$ESP_DEV"
    if [ \$? -ne 0 ]; then
        echo "FATAL: refind-install failed. Check that $EFI_DIR is your mounted ESP (vfat filesystem, esp/boot partition flag set)." >&2
        exit 1
    fi
fi

cat <<'REFINDCONF' > /boot/refind_linux.conf
"Boot with standard options"  "root=UUID=$ROOT_UUID rw"
"Boot to single-user mode"    "root=UUID=$ROOT_UUID rw single"
REFINDCONF
BLEOF
            ;;
        *)
            cat <<BLEOF
if [ "$BOOT_MODE" = "uefi" ]; then
    pacman -S --noconfirm --overwrite="*" grub efibootmgr os-prober
    if [ "$UEFI_NVRAM_OK" = "true" ]; then
        grub-install --target=x86_64-efi --efi-directory="$EFI_DIR" --bootloader-id=Visnux
        if [ \$? -ne 0 ]; then
            echo "WARNING: grub-install with NVRAM registration failed, retrying with --removable (no firmware boot entry will be created)." >&2
            grub-install --target=x86_64-efi --efi-directory="$EFI_DIR" --bootloader-id=Visnux --removable
            if [ \$? -ne 0 ]; then
                echo "FATAL: UEFI grub-install failed even with --removable. Check that $EFI_DIR is your mounted ESP (vfat filesystem, esp/boot partition flag set)." >&2
                exit 1
            fi
        fi
    else
        grub-install --target=x86_64-efi --efi-directory="$EFI_DIR" --bootloader-id=Visnux --removable
        if [ \$? -ne 0 ]; then
            echo "FATAL: UEFI grub-install failed. Check that $EFI_DIR is your mounted ESP (vfat filesystem, esp/boot partition flag set)." >&2
            exit 1
        fi
    fi

    mkdir -p "$EFI_DIR/EFI/BOOT"
    if [ -f "$EFI_DIR/EFI/Visnux/grubx64.efi" ]; then
        cp -f "$EFI_DIR/EFI/Visnux/grubx64.efi" "$EFI_DIR/EFI/BOOT/BOOTX64.EFI" || true
    fi
else
    if [ -z "$GRUB_DISK" ]; then
        echo "FATAL: could not determine the target disk for BIOS grub-install (findmnt/lsblk gave nothing usable - no /dev/sda assumption made). See log for details." >&2
        exit 1
    fi
    pacman -S --noconfirm --overwrite="*" grub os-prober
    grub-install --recheck "$GRUB_DISK"
    if [ \$? -ne 0 ]; then
        echo "FATAL: BIOS grub-install to $GRUB_DISK failed." >&2
        exit 1
    fi
fi

sed -i 's/^#*GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Visnux"/' /etc/default/grub || echo 'GRUB_DISTRIBUTOR="Visnux"' >> /etc/default/grub
sed -i 's/^#*GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub || echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg
BLEOF
            ;;
    esac
}

resolve_bootloader_packages() {
    case "$BOOTLOADER" in
        limine) BL_PKGS="limine efibootmgr" ;;
        refind) BL_PKGS="refind efibootmgr" ;;
        *) BL_PKGS="grub efibootmgr os-prober" ;;
    esac
}

> "$LOGFILE"

dialog --title "Visnux Linux" --msgbox "Welcome to Visnux Linux! Before running the installer, partition your drives. Because we do NOT make your drives, do em yourself\n\n With love,\n v1sta_" 0 0; clear

if ! network_preflight_check; then
    exit 1
fi

while true; do
    MENU=$(dialog --title "Installation Menu" --menu "Choose an option" 22 55 10 \
        1 "User Account" \
        2 "Hostname" \
        3 "Root Password" \
        4 "Init Selection" \
        5 "DE selection" \
        6 "Wi-Fi Setup (optional)" \
        7 "Boot Mode" \
        8 "GPU Drivers" \
        9 "Bootloader" \
        10 "Install" 3>&1 1>&2 2>&3 3>&-)
    
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
                dialog --title "Error" --msgbox "Passwords not match or were left empty. Try again." 0 0; clear
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
                dialog --title "Error" --msgbox "Passwords not match or left empty. Try Again!" 0 0; clear
            fi
        done
    fi
   
    if [ "$MENU" == "4" ]; then
        INIT=$(dialog --title "Init Selection" --menu "Choose your preferred init: " 11 40 4 \
            1 "systemd" \
            2 "openrc" \
            3 "runit" \
            4 "dinit" 3>&1 1>&2 2>&3 3>&-); clear

        if [ -n "$INIT" ]; then
            dialog --title "Mirrors" --infobox "Finding fast mirrors for your location, hang on..." 0 0
            refresh_mirrors
            dialog --title "Mirrors" --msgbox "Mirrors updated!" 0 0; clear
        fi
    fi
   
    if [ "$MENU" == "5" ]; then
        DE=$(dialog --title "DE Selection" --menu "Choose your preferred DE: " 10 40 2 \
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
        CHOICE=$(dialog --title "Boot Mode" --menu "Choose your bios down below:" 11 55 3 \
            1 "Auto-detect (recommended)" \
            2 "Force UEFI" \
            3 "Force BIOS / Legacy" 3>&1 1>&2 2>&3 3>&-); clear

        case "$CHOICE" in
            1) BOOTMODE_CHOICE="" ;;
            2) BOOTMODE_CHOICE="uefi" ;;
            3) BOOTMODE_CHOICE="bios" ;;
        esac

        if [ -n "$CHOICE" ]; then
            LABEL="Auto-detect"
            [ "$BOOTMODE_CHOICE" == "uefi" ] && LABEL="Force UEFI"
            [ "$BOOTMODE_CHOICE" == "bios" ] && LABEL="Force BIOS/Legacy"
            dialog --title "Boot Mode Set" --msgbox "Boot mode set to: $LABEL" 0 0; clear
        fi
    fi

    if [ "$MENU" == "8" ]; then
        CHOICE=$(dialog --title "GPU Drivers" --menu "Choose your GPU driver setup:" 15 70 6 \
            1 "Auto-detect (recommended)" \
            2 "AMD (Mesa + Vulkan)" \
            3 "Intel (Mesa + Vulkan + VA-API)" \
            4 "NVIDIA GTX 16xx / RTX or newer (nvidia-open)" \
            5 "NVIDIA older cards (open-source Nouveau)" \
            6 "Skip / VM (Mesa only)" 3>&1 1>&2 2>&3 3>&-); clear

        case "$CHOICE" in
            1) GPU_CHOICE="" ;;
            2) GPU_CHOICE="amd" ;;
            3) GPU_CHOICE="intel" ;;
            4) GPU_CHOICE="nvidia" ;;
            5) GPU_CHOICE="nouveau" ;;
            6) GPU_CHOICE="none" ;;
        esac

        if [ -n "$CHOICE" ]; then
            resolve_gpu_packages
            dialog --title "GPU Drivers Set" --msgbox "$GPU_LABEL\n\nPackages: $GPU_PKGS" 0 0; clear
        fi
    fi

    if [ "$MENU" == "9" ]; then
        CHOICE=$(dialog --title "Bootloader" --menu "Choose your bootloader:" 12 70 3 \
            1 "GRUB (BIOS + UEFI, dual-boot via os-prober)" \
            2 "Limine (UEFI only)" \
            3 "rEFInd (UEFI only)" 3>&1 1>&2 2>&3 3>&-); clear

        case "$CHOICE" in
            1) BOOTLOADER="grub" ;;
            2) BOOTLOADER="limine" ;;
            3) BOOTLOADER="refind" ;;
        esac

        if [ -n "$CHOICE" ]; then
            BL_NOTE=""
            [ "$BOOTLOADER" == "limine" ] && BL_NOTE="\n\nLimine needs your EFI partition mounted at /mnt/boot."
            [ "$BOOTLOADER" == "refind" ] && BL_NOTE="\n\nrEFInd needs a UEFI system."
            dialog --title "Bootloader Set" --msgbox "Bootloader set to: $BOOTLOADER$BL_NOTE" 0 0; clear
        fi
    fi

    if [ "$MENU" == "10" ]; then

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


        EFIVARS_PRESENT=false
        if [ -d /sys/firmware/efi/efivars ] && [ -n "$(ls -A /sys/firmware/efi/efivars 2>/dev/null)" ]; then
            EFIVARS_PRESENT=true
        fi

        case "$BOOTMODE_CHOICE" in
            uefi) BOOT_MODE="uefi" ;;
            bios) BOOT_MODE="bios" ;;
            *)
                if [ "$EFIVARS_PRESENT" == "true" ]; then
                    BOOT_MODE="uefi"
                else
                    BOOT_MODE="bios"
                fi
                ;;
        esac

        EFI_DIR=""
        if mountpoint -q /mnt/boot/efi 2>/dev/null; then
            EFI_DIR="/boot/efi"
        elif mountpoint -q /mnt/boot 2>/dev/null; then
            EFI_DIR="/boot"
        fi

        if [ "$BOOT_MODE" == "uefi" ] && [ -z "$EFI_DIR" ]; then
            dialog --title "EFI Partition Not Found" --msgbox "You're installing for UEFI, but no EFI System Partition is mounted at /mnt/boot or /mnt/boot/efi.\n\nMount your FAT32 ESP at one of those paths (e.g. mount /dev/sda1 /mnt/boot/efi) and try again." 0 0; clear
            continue
        fi

        if [ "$BOOT_MODE" == "uefi" ] && [ -n "$EFI_DIR" ]; then
            ESP_FSTYPE=$(findmnt -no FSTYPE "/mnt${EFI_DIR}" 2>/dev/null)
            if [ "$ESP_FSTYPE" != "vfat" ]; then
                dialog --title "EFI Partition Warning" --yesno "The partition mounted at $EFI_DIR doesn't look like FAT32/vfat (detected: ${ESP_FSTYPE:-unknown}).\n\nA UEFI ESP must be formatted FAT32 or grub-install will fail. This is also required so an existing Windows/other-OS bootloader on the same ESP stays intact for dual-booting.\n\nContinue anyway?" 0 0
                if [ $? -ne 0 ]; then
                    clear
                    continue
                fi
                clear
            fi
        fi

        UEFI_NVRAM_OK=false
        if [ "$BOOT_MODE" == "uefi" ] && [ "$EFIVARS_PRESENT" == "true" ]; then
            UEFI_NVRAM_OK=true
        fi

        if [ "$BOOT_MODE" == "uefi" ] && [ "$EFIVARS_PRESENT" != "true" ]; then
            dialog --title "Warning: No EFI Variables" --yesno "You're installing for UEFI, but this live session doesn't have EFI variables available.\n\nGrub can still be installed, but no dedicated 'Visnux' entry can be registered in your firmware's boot menu - most firmwares will still boot it as the fallback, but not all.\n\nFor a proper boot entry, reboot the install media in UEFI mode instead.\n\nContinue anyway?" 0 0
            if [ $? -ne 0 ]; then
                clear
                continue
            fi
            clear
        fi

        if [ "$BOOTLOADER" != "grub" ]; then
            if [ "$BOOT_MODE" != "uefi" ]; then
                dialog --title "Bootloader Error" --msgbox "$BOOTLOADER only supports UEFI, but the installer is set to BIOS/Legacy.\n\nChoose GRUB in the Bootloader menu, or fix the Boot Mode." 0 0; clear
                continue
            fi
            if [ -z "$(findmnt -no UUID /mnt 2>/dev/null)" ]; then
                dialog --title "Bootloader Error" --msgbox "Could not read the UUID of the root partition mounted at /mnt, which $BOOTLOADER needs for its boot entry." 0 0; clear
                continue
            fi
        fi

        if [ "$BOOTLOADER" == "limine" ] && [ "$EFI_DIR" != "/boot" ]; then
            dialog --title "Bootloader Error" --msgbox "$BOOTLOADER keeps the kernel and initramfs on the EFI partition, so it must be mounted at /mnt/boot (not /mnt/boot/efi).\n\nRemount it there, or choose GRUB or rEFInd." 0 0; clear
            continue
        fi

        if [ "$BOOTLOADER" == "limine" ] && [ -n "$EFI_DIR" ]; then
            ESP_SIZE_MB=$(df -Pm "/mnt${EFI_DIR}" 2>/dev/null | awk 'NR==2 {print $2}')
            if [ -n "$ESP_SIZE_MB" ] && [ "$ESP_SIZE_MB" -lt 300 ]; then
                dialog --title "EFI Partition Small" --yesno "Your EFI partition is only ${ESP_SIZE_MB} MB. $BOOTLOADER stores the kernel and initramfs images on it, and they need roughly 200-300 MB (more with the fallback initramfs).\n\nContinue anyway?" 0 0
                if [ $? -ne 0 ]; then
                    clear
                    continue
                fi
                clear
            fi
        fi

        dialog --title "Warning!" --yesno "If you click confirm, Visnux Linux will install on your disk/partition at /mnt. THIS ACTION CANNOT BE REVERSED!\n\nSO do it at your own risk!!" 0 0
        
        STATUS=$?
        clear
      
        if [ $STATUS -ne 0 ]; then
            break
        else
            TIMEZONE=$(curl -s --max-time 5 https://ipinfo.io/timezone)
            if [ -z "$TIMEZONE" ] || [ ! -e "/usr/share/zoneinfo/$TIMEZONE" ]; then
                TIMEZONE="UTC"
            fi

            ROOT_PART=$(findmnt -no SOURCE /mnt 2>/dev/null)
            GRUB_DISK=""
            if [ -n "$ROOT_PART" ]; then
                PKNAME=$(lsblk -no pkname "$ROOT_PART" 2>/dev/null)
                [ -n "$PKNAME" ] && GRUB_DISK="/dev/$PKNAME"
            fi
            if [ "$BOOT_MODE" == "bios" ] && [ -z "$GRUB_DISK" ]; then
                echo "WARNING: could not auto-detect the target disk from /mnt (findmnt/lsblk gave nothing usable)." >> "$LOGFILE"
            fi

            ROOT_UUID=$(findmnt -no UUID /mnt 2>/dev/null)
            [ -z "$ROOT_UUID" ] && ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null)
            ESP_DEV=""
            ESP_DISK=""
            ESP_PARTNUM=""
            if [ -n "$EFI_DIR" ]; then
                ESP_DEV=$(findmnt -no SOURCE "/mnt${EFI_DIR}" 2>/dev/null)
                ESP_PKNAME=$(lsblk -no pkname "$ESP_DEV" 2>/dev/null)
                [ -n "$ESP_PKNAME" ] && ESP_DISK="/dev/$ESP_PKNAME"
                ESP_PARTNUM=$(cat "/sys/class/block/$(basename "$ESP_DEV")/partition" 2>/dev/null)
            fi
            resolve_bootloader_packages
            resolve_gpu_packages
            INIT_OK=true
            echo "=== Installing Visnux - be a tree <3 ==="
            fix_keyrings_and_time

#systemd
            if [ "$INIT" == "1" ]; then
                sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /etc/pacman.conf
                
                bootstrap_keyring archlinux-keyring /etc/pacman.conf archlinux

                pacstrap -K /mnt base base-devel linux linux-firmware sof-firmware $BL_PKGS sudo --overwrite="*" 2>&1 | tee -a "$LOGFILE" || INIT_OK=false
                
                if [ "$INIT_OK" == "true" ]; then
                    genfstab -U /mnt > /mnt/etc/fstab
                    setup_chroot_dns
                    setup_wifi_connection

                    sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 12/' /mnt/etc/pacman.conf
                    sed -i '/^ParallelDownloads = 12/a Color\nILoveCandy' /mnt/etc/pacman.conf

                    arch-chroot /mnt /bin/bash 2>&1 <<EOF | tee -a "$LOGFILE"
pacman -Sy --noconfirm archlinux-keyring || true


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
BUILD_ID=rolling
ANSI_COLOR="38;2;85;255;85"
HOME_URL="https://github.com/realv1sta/visnux"
DOCUMENTATION_URL="https://github.com/realv1sta/visnux"
LOGO=visnux
OSSEOF

mkdir -p /etc/skel/.config
mkdir -p /usr/share/icons/hicolor/scalable/apps
mkdir -p /usr/share/pixmaps

pacman -S --noconfirm --overwrite="*" git || true

if git clone https://github.com/beamyyl/fastfetch /tmp/fastfetch-skel; then
    cp -r /tmp/fastfetch-skel/* /etc/skel/.config/ 2>/dev/null || true
    rm -rf /tmp/fastfetch-skel
else
    echo "WARNING: could not clone beamyyl/fastfetch, /etc/skel/.config/fastfetch not seeded" >&2
fi
mkdir -p /etc/skel/.config/fastfetch

if git clone https://github.com/beamyyl/kitty /tmp/kitty-skel; then
    cp -r /tmp/kitty-skel/* /etc/skel/.config/ 2>/dev/null || true
    rm -rf /tmp/kitty-skel
else
    echo "WARNING: could not clone beamyyl/kitty, /etc/skel/.config/kitty not seeded" >&2
fi

if git clone https://github.com/realv1sta/visnux.git /tmp/visnux-assets; then
    [ -f /tmp/visnux-assets/visnux.svg ] && cp /tmp/visnux-assets/visnux.svg /usr/share/icons/hicolor/scalable/apps/visnux.svg
    [ -f /tmp/visnux-assets/visnux.png ] && cp /tmp/visnux-assets/visnux.png /usr/share/pixmaps/visnux.png
    if [ -f /tmp/visnux-assets/colorlogo.sh ]; then
        chmod +x /tmp/visnux-assets/colorlogo.sh
        (cd /tmp/visnux-assets && ./colorlogo.sh > /etc/skel/.config/fastfetch/logo.txt) || echo "WARNING: colorlogo.sh failed, keeping empty logo.txt" >&2
    else
        echo "WARNING: colorlogo.sh not found in visnux repo, keeping logo.txt empty" >&2
    fi
    rm -rf /tmp/visnux-assets
else
    echo "WARNING: could not clone visnux repo, icons/logo not installed" >&2
fi

echo "root:$ROOT" | chpasswd
useradd -m -G wheel "$USER_"
echo "$USER_:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

$(bootloader_chroot_script)

DE_PKGS=""
if [ "$DE" == "1" ]; then
    DE_PKGS="plasma konsole dolphin wl-clipboard kitty fastfetch sddm networkmanager nano sudo power-profiles-daemon"
elif [ "$DE" == "2" ]; then
    DE_PKGS="xorg-server xfce4 xfce4-whiskermenu-plugin xclip maim xfce4-pulseaudio-plugin kitty fastfetch sddm networkmanager nano sudo power-profiles-daemon"
fi

for attempt in 1 2 3; do
    pacman -Syu \$DE_PKGS --overwrite="*" --noconfirm && break
    echo "WARNING: desktop package install failed (attempt \$attempt of 3)." >&2
    if [ "\$attempt" -eq 3 ]; then
        echo "FATAL: desktop packages failed to install after 3 attempts - see the pacman errors above." >&2
        exit 1
    fi
    sleep 5
done

if [ -n "$GPU_PKGS" ]; then
    pacman -S --noconfirm --needed --overwrite="*" $GPU_PKGS || echo "WARNING: GPU driver install failed ($GPU_PKGS), continuing without it." >&2
    case " $GPU_PKGS " in
        *" nvidia-open "*) mkinitcpio -P ;;
    esac
fi

systemctl enable NetworkManager
systemctl enable sddm --force
EOF
                    [ $? -ne 0 ] && INIT_OK=false
                fi
            fi

#openrc
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
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch
Server = https://ftp.crifo.org/artix/repos/\$repo/os/\$arch
Server = https://mirrors.dotsrc.org/artix-linux/repos/\$repo/os/\$arch
Server = https://artix.unixpeople.org/repos/\$repo/os/\$arch
Server = https://artixlinux.mirror.garr.it/\$repo/os/\$arch
Server = https://mirror.freedif.org/artix/\$repo/os/\$arch

[world]
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch
Server = https://ftp.crifo.org/artix/repos/\$repo/os/\$arch
Server = https://mirrors.dotsrc.org/artix-linux/repos/\$repo/os/\$arch
Server = https://artix.unixpeople.org/repos/\$repo/os/\$arch
Server = https://artixlinux.mirror.garr.it/\$repo/os/\$arch
Server = https://mirror.freedif.org/artix/\$repo/os/\$arch

[galaxy]
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch
Server = https://ftp.crifo.org/artix/repos/\$repo/os/\$arch
Server = https://mirrors.dotsrc.org/artix-linux/repos/\$repo/os/\$arch
Server = https://artix.unixpeople.org/repos/\$repo/os/\$arch
Server = https://artixlinux.mirror.garr.it/\$repo/os/\$arch
Server = https://mirror.freedif.org/artix/\$repo/os/\$arch
EOF

                bootstrap_keyring artix-keyring "$ARTIX_CONF" artix
                bootstrap_keyring archlinux-keyring "$ARTIX_CONF" archlinux /etc/pacman.conf

                pacstrap -C "$ARTIX_CONF" /mnt base base-devel openrc elogind-openrc linux linux-firmware sof-firmware $BL_PKGS pipewire pipewire-pulse wireplumber artix-keyring archlinux-keyring artix-mirrorlist sudo git --overwrite="*" 2>&1 | tee -a "$LOGFILE" || INIT_OK=false

                if [ "$INIT_OK" == "true" ]; then
                    cp "$ARTIX_CONF" /mnt/etc/pacman.conf
                    sed -i '/^DatabaseOptional/d' /mnt/etc/pacman.conf
                    grep -q '^ILoveCandy' /mnt/etc/pacman.conf || sed -i '/^Color/a ILoveCandy' /mnt/etc/pacman.conf

                    genfstab -U /mnt > /mnt/etc/fstab
                    setup_chroot_dns
                    setup_wifi_connection

                    arch-chroot /mnt /bin/bash 2>&1 <<EOF | tee -a "$LOGFILE"
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
BUILD_ID=rolling
ANSI_COLOR="38;2;85;255;85"
HOME_URL="https://github.com/realv1sta/visnux"
DOCUMENTATION_URL="https://github.com/realv1sta/visnux"
LOGO=visnux
OSSEOF

mkdir -p /etc/skel/.config
mkdir -p /usr/share/icons/hicolor/scalable/apps
mkdir -p /usr/share/pixmaps

pacman -S --noconfirm --overwrite="*" git || true

if git clone https://github.com/beamyyl/fastfetch /tmp/fastfetch-skel; then
    cp -r /tmp/fastfetch-skel/* /etc/skel/.config/ 2>/dev/null || true
    rm -rf /tmp/fastfetch-skel
else
    echo "WARNING: could not clone beamyyl/fastfetch, /etc/skel/.config/fastfetch not seeded" >&2
fi
mkdir -p /etc/skel/.config/fastfetch

if git clone https://github.com/beamyyl/kitty /tmp/kitty-skel; then
    cp -r /tmp/kitty-skel/* /etc/skel/.config/ 2>/dev/null || true
    rm -rf /tmp/kitty-skel
else
    echo "WARNING: could not clone beamyyl/kitty, /etc/skel/.config/kitty not seeded" >&2
fi

if git clone https://github.com/realv1sta/visnux.git /tmp/visnux-assets; then
    [ -f /tmp/visnux-assets/visnux.svg ] && cp /tmp/visnux-assets/visnux.svg /usr/share/icons/hicolor/scalable/apps/visnux.svg
    [ -f /tmp/visnux-assets/visnux.png ] && cp /tmp/visnux-assets/visnux.png /usr/share/pixmaps/visnux.png
    if [ -f /tmp/visnux-assets/colorlogo.sh ]; then
        chmod +x /tmp/visnux-assets/colorlogo.sh
        (cd /tmp/visnux-assets && ./colorlogo.sh > /etc/skel/.config/fastfetch/logo.txt) || echo "WARNING: colorlogo.sh failed, keeping empty logo.txt" >&2
    else
        echo "WARNING: colorlogo.sh not found in visnux repo, keeping logo.txt empty" >&2
    fi
    rm -rf /tmp/visnux-assets
else
    echo "WARNING: could not clone visnux repo, icons/logo not installed" >&2
fi

echo "root:$ROOT" | chpasswd
useradd -m -G wheel,audio,video "$USER_"
echo "$USER_:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

mkinitcpio -P

$(bootloader_chroot_script)

mkdir -p /usr/local/bin /etc/xdg/autostart

cat <<'AUDIOEOF' > /usr/local/bin/visnux-audio-start
#!/bin/sh
[ -n "\$XDG_RUNTIME_DIR" ] || exit 0
LOG="\$HOME/.visnux-audio.log"
UIDN="\$(id -u)"
has_card() { grep -q '[0-9]' /proc/asound/cards 2>/dev/null; }
i=0
while [ "\$i" -lt 30 ] && ! has_card; do sleep 1; i=\$((i+1)); done
echo "--- visnux-audio-start \$(date) cards-ready=\$(has_card && echo yes || echo no) ---" >> "\$LOG"
pgrep -u "\$UIDN" -x pipewire >/dev/null 2>&1 || pipewire >> "\$LOG" 2>&1 &
sleep 1
pgrep -u "\$UIDN" -x wireplumber >/dev/null 2>&1 || wireplumber >> "\$LOG" 2>&1 &
sleep 1
pgrep -u "\$UIDN" -x pipewire-pulse >/dev/null 2>&1 || pipewire-pulse >> "\$LOG" 2>&1 &
sleep 4
if has_card && ! pactl list short sinks 2>/dev/null | grep -qv auto_null; then
    echo "no real sink found, restarting wireplumber" >> "\$LOG"
    pkill -u "\$UIDN" -x wireplumber
    sleep 1
    wireplumber >> "\$LOG" 2>&1 &
fi
AUDIOEOF
chmod +x /usr/local/bin/visnux-audio-start

cat <<'AUDIODESKEOF' > /etc/xdg/autostart/visnux-audio.desktop
[Desktop Entry]
Type=Application
Name=Visnux Audio
Comment=Starts PipeWire, WirePlumber and PipeWire-Pulse
Exec=/usr/local/bin/visnux-audio-start
Terminal=false
NoDisplay=true
AUDIODESKEOF

DE_PKGS=""
DESKTOP_PKGS=""

if [ "$DE" == "1" ]; then
    DE_PKGS="plasma konsole dolphin"
    DESKTOP_PKGS="kitty fastfetch wl-clipboard sddm sddm-openrc power-profiles-daemon power-profiles-daemon-openrc pipewire pipewire-openrc pipewire-pulse pipewire-pulse-openrc wireplumber wireplumber-openrc pipewire-alsa alsa-utils alsa-utils-openrc"
elif [ "$DE" == "2" ]; then
    DE_PKGS="xorg-server xfce4 xfce4-whiskermenu-plugin xfce4-pulseaudio-plugin"
    DESKTOP_PKGS="kitty fastfetch sddm xclip maim sddm-openrc power-profiles-daemon power-profiles-daemon-openrc pipewire pipewire-openrc pipewire-pulse pipewire-pulse-openrc wireplumber wireplumber-openrc pipewire-alsa alsa-utils alsa-utils-openrc pavucontrol"
fi

for attempt in 1 2 3; do
    pacman -Syu \
        \$DE_PKGS \
        \$DESKTOP_PKGS \
        turnstile turnstile-openrc \
        networkmanager networkmanager-openrc \
        dbus dbus-openrc \
        nano sudo \
        --overwrite="*" --noconfirm && break
    echo "WARNING: desktop package install failed (attempt \$attempt of 3)." >&2
    if [ "\$attempt" -eq 3 ]; then
        echo "FATAL: desktop packages failed to install after 3 attempts - see the pacman errors above." >&2
        exit 1
    fi
    sleep 5
done

if [ -n "$GPU_PKGS" ]; then
    pacman -S --noconfirm --needed --overwrite="*" $GPU_PKGS || echo "WARNING: GPU driver install failed ($GPU_PKGS), continuing without it." >&2
    case " $GPU_PKGS " in
        *" nvidia-open "*) mkinitcpio -P ;;
    esac
fi
EOF
                    [ $? -ne 0 ] && INIT_OK=false

                    if [ "$INIT_OK" == "true" ]; then
                        echo "=== Enabling OpenRC services (self-detecting) ===" >> "$LOGFILE"
                        arch-chroot /mnt /bin/bash 2>&1 <<'SVCEOF' | tee -a "$LOGFILE"
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

for svc in dbus elogind NetworkManager turnstile sddm power-profiles-daemon "alsa*"; do
    enable_openrc_service "$svc"
done
SVCEOF
                        [ $? -ne 0 ] && INIT_OK=false
                    fi
                fi
                rm -f "$ARTIX_CONF"
            fi

#runit
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
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch
Server = https://ftp.crifo.org/artix/repos/\$repo/os/\$arch
Server = https://mirrors.dotsrc.org/artix-linux/repos/\$repo/os/\$arch
Server = https://artix.unixpeople.org/repos/\$repo/os/\$arch
Server = https://artixlinux.mirror.garr.it/\$repo/os/\$arch
Server = https://mirror.freedif.org/artix/\$repo/os/\$arch

[world]
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch
Server = https://ftp.crifo.org/artix/repos/\$repo/os/\$arch
Server = https://mirrors.dotsrc.org/artix-linux/repos/\$repo/os/\$arch
Server = https://artix.unixpeople.org/repos/\$repo/os/\$arch
Server = https://artixlinux.mirror.garr.it/\$repo/os/\$arch
Server = https://mirror.freedif.org/artix/\$repo/os/\$arch

[galaxy]
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch
Server = https://ftp.crifo.org/artix/repos/\$repo/os/\$arch
Server = https://mirrors.dotsrc.org/artix-linux/repos/\$repo/os/\$arch
Server = https://artix.unixpeople.org/repos/\$repo/os/\$arch
Server = https://artixlinux.mirror.garr.it/\$repo/os/\$arch
Server = https://mirror.freedif.org/artix/\$repo/os/\$arch
EOF

                bootstrap_keyring artix-keyring "$ARTIX_CONF" artix
                bootstrap_keyring archlinux-keyring "$ARTIX_CONF" archlinux /etc/pacman.conf

                pacstrap -C "$ARTIX_CONF" /mnt base base-devel runit runit-rc elogind-runit linux linux-firmware sof-firmware $BL_PKGS artix-keyring archlinux-keyring artix-mirrorlist sudo git --overwrite="*" 2>&1 | tee -a "$LOGFILE" || INIT_OK=false

                if [ "$INIT_OK" == "true" ]; then
                    cp "$ARTIX_CONF" /mnt/etc/pacman.conf
                    sed -i '/^DatabaseOptional/d' /mnt/etc/pacman.conf
                    grep -q '^ILoveCandy' /mnt/etc/pacman.conf || sed -i '/^Color/a ILoveCandy' /mnt/etc/pacman.conf

                    genfstab -U /mnt > /mnt/etc/fstab
                    setup_chroot_dns
                    setup_wifi_connection

                    arch-chroot /mnt /bin/bash 2>&1 <<EOF | tee -a "$LOGFILE"
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
BUILD_ID=rolling
ANSI_COLOR="38;2;85;255;85"
HOME_URL="https://github.com/realv1sta/visnux"
DOCUMENTATION_URL="https://github.com/realv1sta/visnux"
LOGO=visnux
OSSEOF

mkdir -p /etc/skel/.config
mkdir -p /usr/share/icons/hicolor/scalable/apps
mkdir -p /usr/share/pixmaps

pacman -S --noconfirm --overwrite="*" git || true

if git clone https://github.com/beamyyl/fastfetch /tmp/fastfetch-skel; then
    cp -r /tmp/fastfetch-skel/* /etc/skel/.config/ 2>/dev/null || true
    rm -rf /tmp/fastfetch-skel
else
    echo "WARNING: could not clone beamyyl/fastfetch, /etc/skel/.config/fastfetch not seeded" >&2
fi
mkdir -p /etc/skel/.config/fastfetch

if git clone https://github.com/beamyyl/kitty /tmp/kitty-skel; then
    cp -r /tmp/kitty-skel/* /etc/skel/.config/ 2>/dev/null || true
    rm -rf /tmp/kitty-skel
else
    echo "WARNING: could not clone beamyyl/kitty, /etc/skel/.config/kitty not seeded" >&2
fi

if git clone https://github.com/realv1sta/visnux.git /tmp/visnux-assets; then
    [ -f /tmp/visnux-assets/visnux.svg ] && cp /tmp/visnux-assets/visnux.svg /usr/share/icons/hicolor/scalable/apps/visnux.svg
    [ -f /tmp/visnux-assets/visnux.png ] && cp /tmp/visnux-assets/visnux.png /usr/share/pixmaps/visnux.png
    if [ -f /tmp/visnux-assets/colorlogo.sh ]; then
        chmod +x /tmp/visnux-assets/colorlogo.sh
        (cd /tmp/visnux-assets && ./colorlogo.sh > /etc/skel/.config/fastfetch/logo.txt) || echo "WARNING: colorlogo.sh failed, keeping empty logo.txt" >&2
    else
        echo "WARNING: colorlogo.sh not found in visnux repo, keeping logo.txt empty" >&2
    fi
    rm -rf /tmp/visnux-assets
else
    echo "WARNING: could not clone visnux repo, icons/logo not installed" >&2
fi

echo "root:$ROOT" | chpasswd
useradd -m -G wheel,audio,video "$USER_"
echo "$USER_:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

mkinitcpio -P

$(bootloader_chroot_script)

mkdir -p /usr/local/bin /etc/xdg/autostart

cat <<'AUDIOEOF' > /usr/local/bin/visnux-audio-start
#!/bin/sh
[ -n "\$XDG_RUNTIME_DIR" ] || exit 0
LOG="\$HOME/.visnux-audio.log"
UIDN="\$(id -u)"
has_card() { grep -q '[0-9]' /proc/asound/cards 2>/dev/null; }
i=0
while [ "\$i" -lt 30 ] && ! has_card; do sleep 1; i=\$((i+1)); done
echo "--- visnux-audio-start \$(date) cards-ready=\$(has_card && echo yes || echo no) ---" >> "\$LOG"
pgrep -u "\$UIDN" -x pipewire >/dev/null 2>&1 || pipewire >> "\$LOG" 2>&1 &
sleep 1
pgrep -u "\$UIDN" -x wireplumber >/dev/null 2>&1 || wireplumber >> "\$LOG" 2>&1 &
sleep 1
pgrep -u "\$UIDN" -x pipewire-pulse >/dev/null 2>&1 || pipewire-pulse >> "\$LOG" 2>&1 &
sleep 4
if has_card && ! pactl list short sinks 2>/dev/null | grep -qv auto_null; then
    echo "no real sink found, restarting wireplumber" >> "\$LOG"
    pkill -u "\$UIDN" -x wireplumber
    sleep 1
    wireplumber >> "\$LOG" 2>&1 &
fi
AUDIOEOF
chmod +x /usr/local/bin/visnux-audio-start

cat <<'AUDIODESKEOF' > /etc/xdg/autostart/visnux-audio.desktop
[Desktop Entry]
Type=Application
Name=Visnux Audio
Comment=Starts PipeWire, WirePlumber and PipeWire-Pulse
Exec=/usr/local/bin/visnux-audio-start
Terminal=false
NoDisplay=true
AUDIODESKEOF

DE_PKGS=""
DESKTOP_PKGS=""

if [ "$DE" == "1" ]; then
    DE_PKGS="plasma konsole dolphin"
    DESKTOP_PKGS="kitty fastfetch wl-clipboard sddm sddm-runit power-profiles-daemon power-profiles-daemon-runit pipewire pipewire-pulse wireplumber pipewire-alsa alsa-utils alsa-utils-runit"
elif [ "$DE" == "2" ]; then
    DE_PKGS="xorg-server xfce4 xfce4-whiskermenu-plugin xfce4-pulseaudio-plugin"
    DESKTOP_PKGS="kitty fastfetch sddm xclip maim sddm-runit power-profiles-daemon power-profiles-daemon-runit pipewire pipewire-pulse wireplumber pipewire-alsa alsa-utils alsa-utils-runit pavucontrol"
fi

for attempt in 1 2 3; do
    pacman -Syu \
        \$DE_PKGS \
        \$DESKTOP_PKGS \
        networkmanager networkmanager-runit \
        dbus dbus-runit \
        nano sudo \
        --overwrite="*" --noconfirm && break
    echo "WARNING: desktop package install failed (attempt \$attempt of 3)." >&2
    if [ "\$attempt" -eq 3 ]; then
        echo "FATAL: desktop packages failed to install after 3 attempts - see the pacman errors above." >&2
        exit 1
    fi
    sleep 5
done

if [ -n "$GPU_PKGS" ]; then
    pacman -S --noconfirm --needed --overwrite="*" $GPU_PKGS || echo "WARNING: GPU driver install failed ($GPU_PKGS), continuing without it." >&2
    case " $GPU_PKGS " in
        *" nvidia-open "*) mkinitcpio -P ;;
    esac
fi
EOF
                    [ $? -ne 0 ] && INIT_OK=false

                    if [ "$INIT_OK" == "true" ]; then
                        echo "=== Enabling runit services (self-detecting) ===" >> "$LOGFILE"
                        arch-chroot /mnt /bin/bash 2>&1 <<'SVCEOF' | tee -a "$LOGFILE"
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

for svc in dbus elogind NetworkManager sddm power-profiles-daemon "alsa*"; do
    enable_runit_service "$svc"
done
SVCEOF
                        [ $? -ne 0 ] && INIT_OK=false
                    fi
                fi
                rm -f "$ARTIX_CONF"
            fi

#dinit
            if [ "$INIT" == "4" ]; then
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
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch
Server = https://ftp.crifo.org/artix/repos/\$repo/os/\$arch
Server = https://mirrors.dotsrc.org/artix-linux/repos/\$repo/os/\$arch
Server = https://artix.unixpeople.org/repos/\$repo/os/\$arch
Server = https://artixlinux.mirror.garr.it/\$repo/os/\$arch
Server = https://mirror.freedif.org/artix/\$repo/os/\$arch

[world]
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch
Server = https://ftp.crifo.org/artix/repos/\$repo/os/\$arch
Server = https://mirrors.dotsrc.org/artix-linux/repos/\$repo/os/\$arch
Server = https://artix.unixpeople.org/repos/\$repo/os/\$arch
Server = https://artixlinux.mirror.garr.it/\$repo/os/\$arch
Server = https://mirror.freedif.org/artix/\$repo/os/\$arch

[galaxy]
Server = https://mirrors.rit.edu/artixlinux/\$repo/os/\$arch
Server = https://ftp.crifo.org/artix/repos/\$repo/os/\$arch
Server = https://mirrors.dotsrc.org/artix-linux/repos/\$repo/os/\$arch
Server = https://artix.unixpeople.org/repos/\$repo/os/\$arch
Server = https://artixlinux.mirror.garr.it/\$repo/os/\$arch
Server = https://mirror.freedif.org/artix/\$repo/os/\$arch
EOF

                bootstrap_keyring artix-keyring "$ARTIX_CONF" artix
                bootstrap_keyring archlinux-keyring "$ARTIX_CONF" archlinux /etc/pacman.conf

                pacstrap -C "$ARTIX_CONF" /mnt base base-devel dinit elogind-dinit linux linux-firmware sof-firmware $BL_PKGS artix-keyring archlinux-keyring artix-mirrorlist sudo git --overwrite="*" 2>&1 | tee -a "$LOGFILE" || INIT_OK=false

                if [ "$INIT_OK" == "true" ]; then
                    cp "$ARTIX_CONF" /mnt/etc/pacman.conf
                    sed -i '/^DatabaseOptional/d' /mnt/etc/pacman.conf
                    grep -q '^ILoveCandy' /mnt/etc/pacman.conf || sed -i '/^Color/a ILoveCandy' /mnt/etc/pacman.conf

                    genfstab -U /mnt > /mnt/etc/fstab
                    setup_chroot_dns
                    setup_wifi_connection

                    arch-chroot /mnt /bin/bash 2>&1 <<EOF | tee -a "$LOGFILE"
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
BUILD_ID=rolling
ANSI_COLOR="38;2;85;255;85"
HOME_URL="https://github.com/realv1sta/visnux"
DOCUMENTATION_URL="https://github.com/realv1sta/visnux"
LOGO=visnux
OSSEOF

mkdir -p /etc/skel/.config
mkdir -p /usr/share/icons/hicolor/scalable/apps
mkdir -p /usr/share/pixmaps

pacman -S --noconfirm --overwrite="*" git || true

if git clone https://github.com/beamyyl/fastfetch /tmp/fastfetch-skel; then
    cp -r /tmp/fastfetch-skel/* /etc/skel/.config/ 2>/dev/null || true
    rm -rf /tmp/fastfetch-skel
else
    echo "WARNING: could not clone beamyyl/fastfetch, /etc/skel/.config/fastfetch not seeded" >&2
fi
mkdir -p /etc/skel/.config/fastfetch

if git clone https://github.com/beamyyl/kitty /tmp/kitty-skel; then
    cp -r /tmp/kitty-skel/* /etc/skel/.config/ 2>/dev/null || true
    rm -rf /tmp/kitty-skel
else
    echo "WARNING: could not clone beamyyl/kitty, /etc/skel/.config/kitty not seeded" >&2
fi

if git clone https://github.com/realv1sta/visnux.git /tmp/visnux-assets; then
    [ -f /tmp/visnux-assets/visnux.svg ] && cp /tmp/visnux-assets/visnux.svg /usr/share/icons/hicolor/scalable/apps/visnux.svg
    [ -f /tmp/visnux-assets/visnux.png ] && cp /tmp/visnux-assets/visnux.png /usr/share/pixmaps/visnux.png
    if [ -f /tmp/visnux-assets/colorlogo.sh ]; then
        chmod +x /tmp/visnux-assets/colorlogo.sh
        (cd /tmp/visnux-assets && ./colorlogo.sh > /etc/skel/.config/fastfetch/logo.txt) || echo "WARNING: colorlogo.sh failed, keeping empty logo.txt" >&2
    else
        echo "WARNING: colorlogo.sh not found in visnux repo, keeping logo.txt empty" >&2
    fi
    rm -rf /tmp/visnux-assets
else
    echo "WARNING: could not clone visnux repo, icons/logo not installed" >&2
fi

echo "root:$ROOT" | chpasswd
useradd -m -G wheel,audio,video "$USER_"
echo "$USER_:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

mkinitcpio -P

$(bootloader_chroot_script)

mkdir -p /usr/local/bin /etc/xdg/autostart

cat <<'AUDIOEOF' > /usr/local/bin/visnux-audio-start
#!/bin/sh
[ -n "\$XDG_RUNTIME_DIR" ] || exit 0
LOG="\$HOME/.visnux-audio.log"
UIDN="\$(id -u)"
has_card() { grep -q '[0-9]' /proc/asound/cards 2>/dev/null; }
i=0
while [ "\$i" -lt 30 ] && ! has_card; do sleep 1; i=\$((i+1)); done
echo "--- visnux-audio-start \$(date) cards-ready=\$(has_card && echo yes || echo no) ---" >> "\$LOG"
pgrep -u "\$UIDN" -x pipewire >/dev/null 2>&1 || pipewire >> "\$LOG" 2>&1 &
sleep 1
pgrep -u "\$UIDN" -x wireplumber >/dev/null 2>&1 || wireplumber >> "\$LOG" 2>&1 &
sleep 1
pgrep -u "\$UIDN" -x pipewire-pulse >/dev/null 2>&1 || pipewire-pulse >> "\$LOG" 2>&1 &
sleep 4
if has_card && ! pactl list short sinks 2>/dev/null | grep -qv auto_null; then
    echo "no real sink found, restarting wireplumber" >> "\$LOG"
    pkill -u "\$UIDN" -x wireplumber
    sleep 1
    wireplumber >> "\$LOG" 2>&1 &
fi
AUDIOEOF
chmod +x /usr/local/bin/visnux-audio-start

cat <<'AUDIODESKEOF' > /etc/xdg/autostart/visnux-audio.desktop
[Desktop Entry]
Type=Application
Name=Visnux Audio
Comment=Starts PipeWire, WirePlumber and PipeWire-Pulse
Exec=/usr/local/bin/visnux-audio-start
Terminal=false
NoDisplay=true
AUDIODESKEOF

DE_PKGS=""
DESKTOP_PKGS=""

if [ "$DE" == "1" ]; then
    DE_PKGS="plasma konsole dolphin"
    DESKTOP_PKGS="kitty fastfetch wl-clipboard sddm sddm-dinit power-profiles-daemon power-profiles-daemon-dinit pipewire pipewire-pulse wireplumber pipewire-alsa alsa-utils alsa-utils-dinit"
elif [ "$DE" == "2" ]; then
    DE_PKGS="xorg-server xfce4 xfce4-whiskermenu-plugin xfce4-pulseaudio-plugin"
    DESKTOP_PKGS="kitty fastfetch sddm xclip maim sddm-dinit power-profiles-daemon power-profiles-daemon-dinit pipewire pipewire-pulse wireplumber pipewire-alsa alsa-utils alsa-utils-dinit pavucontrol"
fi

for attempt in 1 2 3; do
    pacman -Syu \
        \$DE_PKGS \
        \$DESKTOP_PKGS \
        networkmanager networkmanager-dinit \
        dbus dbus-dinit \
        nano sudo \
        --overwrite="*" --noconfirm && break
    echo "WARNING: desktop package install failed (attempt \$attempt of 3)." >&2
    if [ "\$attempt" -eq 3 ]; then
        echo "FATAL: desktop packages failed to install after 3 attempts - see the pacman errors above." >&2
        exit 1
    fi
    sleep 5
done

if [ -n "$GPU_PKGS" ]; then
    pacman -S --noconfirm --needed --overwrite="*" $GPU_PKGS || echo "WARNING: GPU driver install failed ($GPU_PKGS), continuing without it." >&2
    case " $GPU_PKGS " in
        *" nvidia-open "*) mkinitcpio -P ;;
    esac
fi
EOF
                    [ $? -ne 0 ] && INIT_OK=false

                    if [ "$INIT_OK" == "true" ]; then
                        echo "=== Enabling dinit services (self-detecting) ===" >> "$LOGFILE"
                        arch-chroot /mnt /bin/bash 2>&1 <<'SVCEOF' | tee -a "$LOGFILE"
mkdir -p /etc/dinit.d/boot.d

enable_dinit_service() {
    local pattern="$1"
    local svc
    svc=$(find /etc/dinit.d -maxdepth 1 -iname "$pattern" -print -quit 2>/dev/null)
    if [ -n "$svc" ]; then
        ln -sf "../$(basename "$svc")" "/etc/dinit.d/boot.d/$(basename "$svc")"
        echo "Enabled dinit service: $(basename "$svc")"
    else
        echo "WARNING: no dinit service matching '$pattern' found under /etc/dinit.d - skipped" >&2
    fi
}

echo "--- contents of /etc/dinit.d for reference ---"
ls /etc/dinit.d 2>&1

for svc in dbus elogind logind NetworkManager sddm power-profiles-daemon "alsa*"; do
    enable_dinit_service "$svc"
done
SVCEOF
                        [ $? -ne 0 ] && INIT_OK=false
                    fi
                fi
                rm -f "$ARTIX_CONF"
            fi

            if [ "$INIT_OK" == "true" ]; then
                dialog --title "All done!" --msgbox "Installation complete! Reboot into Visnux Linux and Larp Better." 0 0; clear
                break
            else
                show_error_log
            fi
        fi
    fi
        
done
