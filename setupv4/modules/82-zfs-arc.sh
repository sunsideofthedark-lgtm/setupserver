#!/bin/bash
# ==============================================================================
# Modul: zfs-arc
# ==============================================================================
# Setzt die Obergrenze des ZFS ARC (Adaptive Replacement Cache).
# Standardmäßig nutzt ZFS bis zu 50% des RAMs als Cache. Auf Servern mit
# genug RAM und wenig Durchsatz ist eine kleinere, feste Grenze sinnvoller,
# weil der Speicher dann für Anwendungen zur Verfügung steht.
#
# Einstellung wird sofort gesetzt (/sys) und dauerhaft hinterlegt
# (/etc/modprobe.d/zfs.conf), damit sie einen Reboot übersteht.
#
# Config:
#   INSTALL_ZFS_ARC - ARC-Cache konfigurieren (Default false)
#
# Die Cache-Größe wird interaktiv abgefragt (Vorgabe: 8 GB). Bewusst kein
# Config-Schalter: die Größe hängt vom RAM des jeweiligen Servers ab und ist
# damit kein Wert, der sinnvoll in eine gemeinsame setup.conf gehört.
# ==============================================================================

MODULE_ID="zfs-arc"
MODULE_NAME="ZFS ARC-Cache"
MODULE_DESC="ZFS-ARC-Cache auf einen festen Wert begrenzen"
MODULE_ORDER=82
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("zfs" "performance")

ZFS_ARC_PARAM="/sys/module/zfs/parameters/zfs_arc_max"
ZFS_ARC_CONF="/etc/modprobe.d/zfs.conf"

zfs_available() {
    command -v zpool >/dev/null 2>&1 && zpool list >/dev/null 2>&1
}

zfs_show_memory() {
    local total_ram_mb total_ram_gb
    total_ram_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    total_ram_gb=$((total_ram_mb / 1024))
    info "Verfügbarer Arbeitsspeicher: ${total_ram_gb}GB (${total_ram_mb}MB)"
}

zfs_show_current() {
    local current_arc_max current_arc_gb
    current_arc_max=$(cat "$ZFS_ARC_PARAM" 2>/dev/null || echo "nicht gesetzt")

    if [ "$current_arc_max" != "nicht gesetzt" ] && [ "$current_arc_max" -gt 0 ] 2>/dev/null; then
        current_arc_gb=$((current_arc_max / 1024 / 1024 / 1024))
        info "Aktueller zfs_arc_max: ${current_arc_gb}GB"
    else
        info "Aktueller zfs_arc_max: nicht gesetzt (Standard: 50% des RAMs)"
    fi
}

module_main() {
    local zfs_cache_gb cache_bytes

    if ! config_bool INSTALL_ZFS_ARC; then
        skip "ZFS ARC-Cache ist nicht aktiviert (INSTALL_ZFS_ARC=false)."
        return 1
    fi

    info "Prüfe ZFS-Dateisystem..."

    if ! zfs_available; then
        info "Kein ZFS-Dateisystem erkannt - überspringe ZFS-Cache-Konfiguration."
        return 1
    fi

    success "ZFS-Dateisystem erkannt."

    if ! ask_yes_no "Möchten Sie einen ZFS ARC-Cache konfigurieren?" "n"; then
        info "ZFS ARC-Cache-Konfiguration übersprungen."
        return 1
    fi

    zfs_show_memory
    zfs_show_current

    # Im nicht-interaktiven Modus wird die Vorgabe verwendet
    if ! ask_value "Gewünschte Cache-Größe in GB" "8" zfs_cache_gb; then
        return 2
    fi

    if [[ ! "$zfs_cache_gb" =~ ^[0-9]+$ ]] || [ "$zfs_cache_gb" -le 0 ]; then
        error "Ungültige Eingabe. Cache-Größe muss eine positive Zahl sein."
        return 2
    fi

    cache_bytes=$((zfs_cache_gb * 1024 * 1024 * 1024))

    # Temporär setzen
    run_eval "echo '${cache_bytes}' > ${ZFS_ARC_PARAM}"
    if [ "$DRY_RUN" != "1" ]; then
        success "ZFS ARC-Cache temporär auf ${zfs_cache_gb}GB gesetzt."
    fi

    # Permanent in /etc/modprobe.d/zfs.conf
    create_backup "$ZFS_ARC_CONF"
    run_cmd mkdir -p /etc/modprobe.d
    run_eval "echo 'options zfs zfs_arc_max=${cache_bytes}' > ${ZFS_ARC_CONF}"
    if [ "$DRY_RUN" != "1" ]; then
        success "ZFS ARC-Cache permanent in ${ZFS_ARC_CONF} konfiguriert."
    fi

    # Initramfs aktualisieren (wichtig für ZFS-Root-Systeme)
    if command -v update-initramfs >/dev/null 2>&1; then
        info "Aktualisiere Initramfs..."
        run_cmd update-initramfs -u
        if [ "$DRY_RUN" != "1" ]; then
            success "Initramfs aktualisiert - Cache-Einstellung wird beim Boot geladen."
        fi
    fi

    log_action "ZFS" "ARC cache configured to ${zfs_cache_gb}GB"
    return 0
}

module_status() {
    local current_arc_max current_arc_gb

    if ! zfs_available; then
        echo "kein ZFS-Dateisystem"
        return 0
    fi

    current_arc_max=$(cat "$ZFS_ARC_PARAM" 2>/dev/null || echo "")
    if [ -n "$current_arc_max" ] && [ "$current_arc_max" -gt 0 ] 2>/dev/null; then
        current_arc_gb=$((current_arc_max / 1024 / 1024 / 1024))
        echo "zfs_arc_max auf ${current_arc_gb}GB begrenzt"
    else
        echo "zfs_arc_max nicht gesetzt (Standard: 50% des RAMs)"
    fi
}