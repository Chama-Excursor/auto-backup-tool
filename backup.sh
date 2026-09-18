#!/usr/bin/env bash
#
# autobackup – YAML-konfiguriertes Backup-Skript für VPS / Docker-Pfade
#
# Aufruf:
#   autobackup [PFAD_ZUR_KONFIG]
#
# Standard-Konfiguration: /etc/autobackup/backup.yml
# Dokumentation:          README.md

set -u
set -o pipefail

VERSION="1.0.0"

CONFIG="${1:-/etc/autobackup/backup.yml}"

# ---------------------------------------------------------------------------
# Globale Standardwerte (werden durch die Konfiguration überschrieben)
# ---------------------------------------------------------------------------
LOG_FILE="/var/log/autobackup.log"

NOTIFY_TYPE=""              # "" || "gotify" || "webhook"
NOTIFY_URL=""               # z.B. https://gotify.example.com
NOTIFY_TOKEN=""             # direkt angegebenes Token (optional)
NOTIFY_TOKEN_FILE=""        # alternativ: Datei, in der das Token steht
NOTIFY_TITLE="Autobackup"
NOTIFY_ON_ERROR="false"

# Backup-Jobs
JOB_COUNT=0
declare -a JOB_NAME JOB_SRC JOB_DEST JOB_METHOD JOB_KEEP_DAYS JOB_KEEP_COUNT
declare -a JOB_ENABLED JOB_NOTIFY JOB_EXCLUDES

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
autobackup $VERSION – Backup-Skript mit YAML-Konfiguration

Verwendung:
  autobackup [PFAD_ZUR_KONFIG]

Optionen:
  -h, --help   Zeigt diese Hilfe an

Standard-Konfigurationspfad:
  /etc/autobackup/backup.yml

Dokumentation und Beispiele: README.md
EOF
}

# Inline-Kommentar entfernen ("wert # kommentar"), Quoting wird beachtet
_strip_comment() {
  local s="$1" out="" i c inq=""
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:$i:1}"
    if [ -z "$inq" ]; then
      if [ "$c" = '"' ] || [ "$c" = "'" ]; then
        inq="$c"
      elif [ "$c" = '#' ] && [ "$i" -gt 0 ] && [[ "${s:$((i - 1)):1}" == ' ' || "${s:$((i - 1)):1}" == $'\t' ]]; then
        break
      fi
    elif [ "$c" = "$inq" ]; then
      inq=""
    fi
    out="$out$c"
  done
  printf '%s' "$out"
}

# Führende/trailing Whitespace entfernen
_trim() {
  printf '%s' "$1" | sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//'
}

# YAML-Wert extrahieren ("key: wert", "- wert" bzw. mit Quoting)
_val() {
  printf '%s' "$1" | sed -E \
    -e 's/^[[:space:]]*//' \
    -e 's/-[[:space:]]+//' \
    -e 's/^[a-zA-Z_][a-zA-Z0-9_-]*:[[:space:]]*//' \
    -e 's/[[:space:]]+$//' \
    -e 's/^"(.*)"$/\1/' \
    -e "s/^'(.*)'$/\1/"
}

# Wahrheitswert normalisieren
_bool() {
  case "$1" in
    true|TRUE|yes|YES|on|ON|1) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

log() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

die() {
  log "FATAL: $*"
  exit 1
}

# Alle Backup-Targets eines Jobs (neueste zuerst).
# Es werden nur Einträge berücksichtigt, die dem Namensschema
#   <name>_JJJJMMTT_HHMMSS*  entsprechen.
_ts_list() {
  ls -1d "$1"/"$2"_????????_??????* 2>/dev/null | sort -r
}

# ---------------------------------------------------------------------------
# Konfiguration parsen (minimaler YAML-Parser, keine externen Tools)
# ---------------------------------------------------------------------------

parse_config() {
  [ -f "$CONFIG" ] || die "Konfigurationsdatei nicht gefunden: $CONFIG"

  local rawline line section="" job=-1 content key leading

  while IFS= read -r rawline || [ -n "$rawline" ]; do
    rawline="$(_strip_comment "$rawline")"
    line="$(_trim "$rawline")"
    case "$line" in
      '' | \#*) continue ;;
    esac

    # Top-Level-Bereiche: notify / backups / log_file (nicht eingerückt)
    leading="${rawline%%[^[:space:]]*}"
    if [ -z "$leading" ]; then
      key="${line%%:*}"
      case "$key" in
        notify | backups) section="$key" ;;
        log_file) LOG_FILE="$(_val "$rawline")" ;;
        *) : ;;  # unbekannte Top-Level-Zeile ignorieren
      esac
      continue
    fi

    # notify-Bereich
    if [ "$section" = "notify" ]; then
      key="${line%%:*}"
      case "$key" in
        url)             NOTIFY_URL="$(_val "$rawline")" ;;
        token)           NOTIFY_TOKEN="$(_val "$rawline")" ;;
        token_file)      NOTIFY_TOKEN_FILE="$(_val "$rawline")" ;;
        type)            NOTIFY_TYPE="$(_val "$rawline")" ;;
        title)           NOTIFY_TITLE="$(_val "$rawline")" ;;
        notify_on_error) NOTIFY_ON_ERROR="$(_val "$rawline")" ;;
      esac
      continue
    fi

    # backups-Bereich
    if [ "$section" = "backups" ]; then
      if [[ "$line" == -* ]]; then
        content="$(printf '%s' "${line#-}" | sed -E 's/^[[:space:]]+//')"
        if [[ "$content" == name:* ]]; then
          job=$((job + 1))
          JOB_COUNT=$((JOB_COUNT + 1))
          JOB_NAME[$job]="$(_val "$rawline")"
          JOB_SRC[$job]=""
          JOB_DEST[$job]=""
          JOB_METHOD[$job]="tar"
          JOB_KEEP_DAYS[$job]=""
          JOB_KEEP_COUNT[$job]=""
          JOB_ENABLED[$job]="true"
          JOB_NOTIFY[$job]="true"
          JOB_EXCLUDES[$job]=""
        elif [ "$job" -ge 0 ]; then
          # Exclude-Eintrag:   - "pattern"
          JOB_EXCLUDES[$job]="${JOB_EXCLUDES[$job]}$(_val "$rawline");"
        fi
      elif [ "$job" -ge 0 ]; then
        key="${line%%:*}"
        case "$key" in
          source)      JOB_SRC[$job]="$(_val "$rawline")" ;;
          destination) JOB_DEST[$job]="$(_val "$rawline")" ;;
          method)      JOB_METHOD[$job]="$(_val "$rawline")" ;;
          keep_days)   JOB_KEEP_DAYS[$job]="$(_val "$rawline")" ;;
          keep_count)  JOB_KEEP_COUNT[$job]="$(_val "$rawline")" ;;
          enabled)     JOB_ENABLED[$job]="$( _bool "$(_val "$rawline")" )" ;;
          notify)      JOB_NOTIFY[$job]="$( _bool "$(_val "$rawline")" )" ;;
          exclude)     : ;;   # Liste beginnt; Items folgen als eigene Zeilen
        esac
      fi
    fi
  done < "$CONFIG"

  [ "$JOB_COUNT" -gt 0 ] || die "Keine Backup-Jobs in $CONFIG gefunden."

  # Token ggf. aus separater Datei laden
  if [ -n "$NOTIFY_TOKEN_FILE" ]; then
    if [ -f "$NOTIFY_TOKEN_FILE" ]; then
      NOTIFY_TOKEN="$(_trim "$(cat "$NOTIFY_TOKEN_FILE")")"
    else
      log "WARNUNG: notify.token_file nicht gefunden: $NOTIFY_TOKEN_FILE"
    fi
  fi

  [ -n "$NOTIFY_URL" ] && NOTIFY_URL="${NOTIFY_URL%/}"
  [ -n "$NOTIFY_TYPE" ] || NOTIFY_TYPE="gotify"
}

# ---------------------------------------------------------------------------
# Benachrichtigung (Gotify oder generischer Webhook)
# ---------------------------------------------------------------------------

notify() {
  local subject="$1" message="$2"
  [ -n "$NOTIFY_URL" ] || return 0
  command -v curl >/dev/null 2>&1 || {
    log "WARNUNG: curl nicht installiert – Benachrichtigung übersprungen"
    return 1
  }

  local code payload
  payload="{\"title\":\"${NOTIFY_TITLE} – $subject\",\"message\":\"$message\"}"

  if [ "$NOTIFY_TYPE" = "webhook" ]; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' -m 20 \
      -H 'Content-Type: application/json' -X POST \
      --data "$payload" "$NOTIFY_URL" 2>>"$LOG_FILE")"
  else
    # gotify
    [ -n "$NOTIFY_TOKEN" ] || {
      log "WARNUNG: kein Gotify-Token gesetzt (notify.token oder notify.token_file)"
      return 1
    }
    payload="{\"title\":\"${NOTIFY_TITLE} – $subject\",\"message\":\"$message\",\"priority\":5}"
    code="$(curl -sS -o /dev/null -w '%{http_code}' -m 20 \
      -H 'Content-Type: application/json' -X POST \
      --data "$payload" "${NOTIFY_URL}/message?token=${NOTIFY_TOKEN}" 2>>"$LOG_FILE")"
  fi

  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    log "Benachrichtigung gesendet (HTTP $code)"
    return 0
  fi
  log "WARNUNG: Benachrichtigung fehlgeschlagen (HTTP $code)"
  return 1
}

# ---------------------------------------------------------------------------
# Rotation: alte Backups entfernen (nach Tagen und/oder Anzahl)
# ---------------------------------------------------------------------------

rotate() {
  local dest="$1" name="$2" days="$3" count="$4"
  local bklist n k

  # 1) Nach Tagen: Einträge, die älter als N*24h sind (GNU find -mtime)
  if [ -n "$days" ] && [ "$days" -gt 0 ] 2>/dev/null; then
    find "$dest" -maxdepth 1 -type f -name "${name}_????????_??????.tar.gz" \
      -mtime +"$days" -delete 2>>"$LOG_FILE"
    find "$dest" -maxdepth 1 -type d -name "${name}_????????_??????" \
      -mtime +"$days" -exec rm -rf {} + 2>>"$LOG_FILE"
    log "Rotation ($name): älter als ${days} Tag(e) entfernt"
  fi

  # 2) Nach Anzahl: nur die neuesten N Einträge behalten
  if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
    mapfile -t bklist < <(_ts_list "$dest" "$name")
    n="${#bklist[@]}"
    if [ "$n" -gt "$count" ]; then
      for ((k=count; k<n; k++)); do
        log "Rotation ($name): lösche altes Backup ${bklist[$k]}"
        rm -rf "${bklist[$k]}"
      done
    fi
  fi
}

# ---------------------------------------------------------------------------
# Einzelnen Backup-Job ausführen
# ---------------------------------------------------------------------------

run_job() {
  local i="$1"
  local name="${JOB_NAME[$i]}"
  local src="${JOB_SRC[$i]}"
  local dest="${JOB_DEST[$i]}"
  local method="${JOB_METHOD[$i]:-tar}"
  local enable="${JOB_ENABLED[$i]:-true}"
  local do_notify="${JOB_NOTIFY[$i]:-true}"
  local keep_days="${JOB_KEEP_DAYS[$i]}"
  local keep_count="${JOB_KEEP_COUNT[$i]}"
  local ts target prev size ex
  local -a exargs=()

  if [ "$enable" != "true" ]; then
    log "ÜBERSPRINGE $name (enabled: false)"
    return 0
  fi
  if [ -z "$src" ] || [ -z "$dest" ]; then
    log "ÜBERSPRINGE $name (source/destination fehlt in Konfiguration)"
    return 0
  fi
  if [ ! -e "$src" ]; then
    log "FEHLER $name: Quelle existiert nicht: $src"
    [ "$do_notify" = "true" ] && [ "$NOTIFY_ON_ERROR" = "true" ] \
      && notify "$name – FEHLER" "Quelle existiert nicht: $src"
    return 1
  fi

  # Ziel darf nicht innerhalb der Quelle liegen (Endlosschleife / rekursives Backup)
  case "${dest%/}/" in
    "${src%/}/"*)
      log "FEHLER $name: Ziel ($dest) liegt innerhalb der Quelle ($src)"
      return 1
      ;;
  esac

  mkdir -p "$dest" || {
    log "FEHLER $name: Zielverzeichnis kann nicht angelegt werden: $dest"
    [ "$do_notify" = "true" ] && [ "$NOTIFY_ON_ERROR" = "true" ] \
      && notify "$name – FEHLER" "Zielverzeichnis kann nicht angelegt werden: $dest"
    return 1
  }

  # Excludes aus Konfiguration
  local exarr
  IFS=';' read -ra exarr <<< "${JOB_EXCLUDES[$i]}"
  for ex in "${exarr[@]}"; do
    [ -n "$ex" ] && exargs+=(--exclude "$ex")
  done

  ts="$(date +%Y%m%d_%H%M%S)"

  case "$method" in
    tar)
      command -v tar >/dev/null 2>&1 || {
        log "FEHLER $name: tar ist nicht installiert"
        return 1
      }
      target="${dest}/${name}_${ts}.tar.gz"
      if tar ${exargs[@]+"${exargs[@]}"} -czf "$target" \
           -C "$(dirname "$src")" "$(basename "$src")" 2>>"$LOG_FILE"; then
        size="$(du -sh "$target" 2>/dev/null | cut -f1)"
        log "OK   $name: $target ($size)"
        rotate "$dest" "$name" "$keep_days" "$keep_count"
        [ "$do_notify" = "true" ] && notify "$name – OK" "Backup erfolgreich: $target ($size)"
      else
        log "FEHLER $name: tar fehlgeschlagen"
        rm -f "$target"
        [ "$do_notify" = "true" ] && [ "$NOTIFY_ON_ERROR" = "true" ] \
          && notify "$name – FEHLER" "tar-Backup fehlgeschlagen: $src"
        return 1
      fi
      ;;
    rsync)
      command -v rsync >/dev/null 2>&1 || {
        log "FEHLER $name: rsync ist nicht installiert"
        return 1
      }
      target="${dest}/${name}_${ts}"
      prev="$(_ts_list "$dest" "$name" | head -1)"
      [ "$prev" = "$target" ] && prev=""
      mkdir -p "$target"
      if rsync -a --delete ${exargs[@]+"${exargs[@]}"} ${prev:+--link-dest="$prev"} \
           "$src/" "$target/" 2>>"$LOG_FILE"; then
        size="$(du -sh "$target" 2>/dev/null | cut -f1)"
        log "OK   $name: $target ($size)"
        rotate "$dest" "$name" "$keep_days" "$keep_count"
        [ "$do_notify" = "true" ] && notify "$name – OK" "Backup erfolgreich: $target ($size)"
      else
        log "FEHLER $name: rsync fehlgeschlagen"
        rm -rf "$target"
        [ "$do_notify" = "true" ] && [ "$NOTIFY_ON_ERROR" = "true" ] \
          && notify "$name – FEHLER" "rsync-Backup fehlgeschlagen: $src"
        return 1
      fi
      ;;
    *)
      log "FEHLER $name: unbekannte Methode '$method' (erlaubt: tar, rsync)"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  # Lock verhindert parallele Läufe (z.B. doppelter Cron-Aufruf)
  exec 9>"${TMPDIR:-/tmp}/autobackup.lock"
  if ! flock -n 9; then
    printf '%s  FATAL: Es läuft bereits eine Autobackup-Instanz.\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$LOG_FILE"
    exit 1
  fi

  parse_config

  log "===== Autobackup gestartet ($(date '+%Y-%m-%d %H:%M:%S')) ====="
  log "Konfiguration: $CONFIG  |  Jobs: $JOB_COUNT"

  local failures=0 i
  for ((i = 0; i < JOB_COUNT; i++)); do
    run_job "$i" || failures=$((failures + 1))
  done

  if [ "$failures" -gt 0 ]; then
    log "===== Autobackup beendet mit $failures Fehler(n) ====="
    exit 1
  fi
  log "===== Autobackup erfolgreich beendet ====="
  exit 0
}

case "${1:-}" in
  -h | --help | help) usage && exit 0 ;;
esac

main "$@"