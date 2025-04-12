#!/bin/bash
##########################################################################################
# ----------------------------------------------------------------------------------------
# Holstein IT-Solutions Inh. Benedict Schultz
# Copyright (C) 2025 Benedict Schultz
# Autoren: Marek Slodkowski, Michael Bielicki
#
# Dieses Programm ist freie Software: Sie können es unter den Bedingungen der
# Affero General Public License (AGPL), Version 3, die mit diesem Programm
# verteilt wird, weiterverbreiten und/oder ändern.
#
# Dieses Programm wird in der Hoffnung, dass es nützlich ist, aber OHNE JEDE
# GARANTIE, sogar ohne die stillschweigende Garantie der MARKTGÄNGIGKEIT oder
# DER EIGNUNG FÜR EINEN BESTIMMTEN ZWECK, verteilt. Weitere Details finden Sie
# in der Affero General Public License, Version 3.
#
# Sie sollten eine Kopie der Affero General Public License zusammen mit diesem
# Programm erhalten haben. Wenn nicht, siehe <http://www.gnu.org/licenses/agpl-3.0.html>.
#
# ----------------------------------------------------------------------------------------
# TrueNAS Benutzer-Migration von SMB zu ZFS
# ----------------------------------------------------------------------------------------
#
# Dieses Skript migriert Benutzerverzeichnisse vom SMB-Mount zu einem ZFS-Pool.
# - Erstellt ZFS-Datasets mit Quotas
# - Kopiert Daten mit rsync
# - Unterstützt Dry-Run-Modus
# - Ermöglicht Ausschluss einzelner Benutzer
# - Setzt NFSv4 ACLs korrekt (per UID)
# - Sendet optional einen E-Mail-Report
##########################################################################################

### === KONFIGURATION ===

MAIN_PATH="/mnt"                                   # Basis-Pfad für ZFS-Mounts
MAIN_POOL="tank"                                   # ZFS-Pool-Name
MAIN_DATASET="userfiles"                           # Haupt-Dataset für Benutzerdaten
SOURCE_MOUNT="/mnt/oldhomes"                       # Quelle: gemountetes SMB-Share
QUOTA="1G"                                         # Speicherbegrenzung je Benutzer
LOGFILE="./migration.log"                          # Logdatei zur Protokollierung
MAILTO=                                            # Optional: E-Mail-Adresse für Bericht (leer = deaktiviert)
AD_DOMAIN="HITS"                                   # Active Directory-Domäne für Benutzerauflösung

# Benutzer, die ausgelassen werden sollen (kommagetrennt, keine Leerzeichen)
SKIP_USERS="test,guest,admin"

# Berechtigungen für NFSv4 ACL (lesen, schreiben, ausführen, etc.)
NFS4_ACL_STRING="rwxpDdaARWcCos:fd:allow"         

# ----------------------------------------------------------------------------------------
# NFSv4 ACL String (kann angepasst werden)
# ----------------------------------------------------------------------------------------
# Der folgende ACL-String wird für jeden Benutzer, der in ein ZFS-Dataset
# migriert wird, auf das Zielverzeichnis angewendet. Der String definiert
# die Berechtigungen, die der Benutzer für das Ziel-Dataset erhält.
#
# Die Struktur des ACL-Strings folgt dem Format:
# "rwxpDdaARWcCos:fd:allow"
#
# Weitere Informationen und eine detaillierte Dokumentation zu den NFSv4 ACLs
# finden Sie auf der folgenden Webseite:
# - https://linux.die.net/man/1/nfs4_setfacl
# ----------------------------------------------------------------------------------------

### === Dry-Run prüfen ===

# Wenn das Skript mit dem Parameter --dry-run gestartet wird,
# wird kein echter Schreibzugriff ausgeführt – nur simuliert.
DRYRUN=false
if [ "$1" == "--dry-run" ]; then
    DRYRUN=true
    echo ">>> [⏭] Dry-Run-Modus aktiviert"
    echo ">>> [⏭] Dry-Run-Modus aktiviert" >> "$LOGFILE"
fi

### === Hilfsfunktionen ===

# Gibt eine Nachricht sowohl auf der Konsole als auch im Logfile aus
log() {
    echo "$1"
    echo "$1" >> "$LOGFILE"
}

# Führt einen Befehl aus oder zeigt ihn nur im Dry-Run-Modus
run() {
    if $DRYRUN; then
        log "    [dry-run] $*"
    else
        eval "$@"
    fi
}

# Prüft, ob ein Benutzer übersprungen werden soll
should_skip_user() {
    local username="$1"
    [[ ",$SKIP_USERS," == *",$username,"* ]]
}

# Sendet das Logfile per Mail, falls MAILTO gesetzt ist
send_report() {
    if [ -n "$MAILTO" ]; then
        mail -s "TrueNAS Migration Report" "$MAILTO" < "$LOGFILE"
        log ">>> 📧 Bericht an $MAILTO gesendet."
    fi
}

# Setzt ACLs auf einem Ziel-Dataset anhand der UID des Benutzers
set_acl() {
    if [ "$#" -ne 1 ]; then
        log "   [✗] Fehler: set_acl erwartet genau 1 Parameter, aber $# erhalten!"
        return 1
    fi

    local USERPATH="$1"
    local USERNAME=$(basename "$USERPATH")

    log "   -> Setze ACL für $USERNAME"

    # Definiere den Dataset-Pfad ohne /mnt
    local DATASET_PATH="${MAIN_POOL}/${MAIN_DATASET}/${USERNAME}"

    # Der vollständige Mount-Pfad für den Dataset (inklusive /mnt)
    local MOUNT_PATH="${MAIN_PATH}/${DATASET_PATH}"

    log "   -> Überprüfe ACL für Dataset: $DATASET_PATH"

    # AD-Domain und Benutzername für die UID-Auflösung
    local FQ_USER="${AD_DOMAIN}\\${USERNAME}"
    log "   -> Teste getent für: $FQ_USER"
    local USER_UID=$(getent passwd "$FQ_USER" | cut -d: -f3)

    if [ -z "$USER_UID" ]; then
        log "   [✗] Konnte UID für $USERNAME ($FQ_USER) nicht auflösen"
        return 1
    fi

    log "   [✓] UID für $USERNAME ($FQ_USER) ist: $USER_UID"

    # ZFS ACL-Eigenschaften setzen, ohne /mnt
    if ! zfs set acltype=nfsv4 "$DATASET_PATH"; then
        log "   [✗] Fehler beim Setzen des ACL-Typs für $USERNAME auf $DATASET_PATH"
    fi

    if ! zfs set xattr=sa "$DATASET_PATH"; then
        log "   [✗] Fehler beim Setzen von xattr=sa für $USERNAME auf $DATASET_PATH"
    fi

    if ! zfs set aclmode=passthrough "$DATASET_PATH"; then
        log "   [✗] Fehler beim Setzen von aclmode=passthrough für $USERNAME auf $DATASET_PATH"
    fi

    # Anwenden der tatsächlichen NFSv4 ACL mit Benutzer-UID, hier wird MOUNT_PATH verwendet
    if ! nfs4xdr_setfacl -a "user:${USER_UID}:${NFS4_ACL_STRING}" "$MOUNT_PATH"; then
        log "   [✗] Fehler beim Setzen der NFSv4 ACL für $USERNAME (UID $USER_UID) auf $MOUNT_PATH"
    else
        log "   [✓] NFSv4 ACL für $USERNAME (UID $USER_UID) auf $MOUNT_PATH gesetzt."
    fi
}


### === Startmeldung ===

log ">>> Starte das Migrationsskript"
log ">>> Quelle: $SOURCE_MOUNT"
log ">>> Ziel: ${MAIN_POOL}/${MAIN_DATASET}"
$DRYRUN && log ">>> Modus: Dry-Run (Simulation)"
log ">>> Benutzer ausschließen: $SKIP_USERS"

# Prüfen, ob das Quellverzeichnis gemountet ist
if ! mountpoint -q "$SOURCE_MOUNT"; then
    log "   [✗] Fehler: Quelle $SOURCE_MOUNT ist nicht gemountet. Abbruch."
    exit 1
fi

### === Schritt 1: Haupt-Dataset prüfen/erstellen ===

# Setzt die vollständigen Namen für das Root-Dataset und den Mountpfad zusammen
ROOT_FULL="${MAIN_POOL}/${MAIN_DATASET}"
ROOT_MOUNT="${MAIN_PATH}/${ROOT_FULL}"

# Prüfen, ob das Haupt-Dataset bereits existiert – wenn nicht, wird es erstellt
if ! zfs list "$ROOT_FULL" >/dev/null 2>&1; then
    log "-> Erstelle Haupt-Dataset: $ROOT_FULL"
    run zfs create "$ROOT_FULL"
else
    log "-> Haupt-Dataset $ROOT_FULL existiert bereits."
fi

### === Schritt 2: Benutzer-Subdatasets erstellen ===

# Liste aller Unterordner im Quellverzeichnis ermitteln (Benutzerverzeichnisse)
USER_FOLDERS=()
for folder in "$SOURCE_MOUNT"/*; do
    [ -d "$folder" ] && USER_FOLDERS+=("$folder")
done

# Jedes Benutzerverzeichnis verarbeiten
for src_folder in "${USER_FOLDERS[@]}"; do
    username=$(basename "$src_folder")

    if should_skip_user "$username"; then
        log "   [⏭] Benutzer '$username' ist in SKIP_USERS. Überspringe."
        continue
    fi

    subdataset="${ROOT_FULL}/${username}"
    submount="${MAIN_PATH}/${subdataset}"

    log "-> Verarbeite Benutzer '$username'"

    # Subdataset nur erstellen, wenn es noch nicht existiert
    if zfs list "$subdataset" >/dev/null 2>&1; then
        log "   [!] Subdataset $subdataset existiert bereits. Überspringe Erstellung."
        continue
    fi

    log "   -> Erstelle Subdataset $subdataset mit Quota $QUOTA"
    run zfs create -o quota="$QUOTA" "$subdataset"
    log "   [✓] Subdataset für $username erstellt."

    # Setzen der ACLs für das neu erstellte Dataset
    set_acl "$submount"

done

log ">>> [✓] Alle Subdatasets verarbeitet."

### === Schritt 3: Daten kopieren ===

# Kopiert Benutzerdaten von der Quelle zum Ziel
for src_folder in "${USER_FOLDERS[@]}"; do
    username=$(basename "$src_folder")

    if should_skip_user "$username"; then
        continue
    fi

    dst_mount="${MAIN_PATH}/${ROOT_FULL}/${username}"

    # Zielverzeichnis muss vorhanden sein
    if [ ! -d "$dst_mount" ]; then
        log "   [✗] Zielverzeichnis für '$username' fehlt. Überspringe Kopieren."
        continue
    fi

    log "-> Kopiere Dateien für Benutzer '$username'"

    # Tatsächlicher Kopiervorgang oder nur Anzeige im Dry-Run
    if $DRYRUN; then
        log "    [dry-run] rsync -a --info=progress2 '$src_folder/' '$dst_mount/'"
    else
        rsync -a --info=progress2 "$src_folder/" "$dst_mount/"
        if [ $? -eq 0 ]; then
            log "   [✓] Dateien erfolgreich kopiert für $username"
        else
            log "   [✗] Fehler beim Kopieren der Dateien für $username"
        fi
    fi

done

log ">>> [✓] Migration abgeschlossen."

### === Schritt 4: Bericht senden (optional) ===

send_report
