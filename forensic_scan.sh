#!/bin/bash
#===============================================================================
# VARREdura Forense - Navegadores, Downloads, Screenshots e Metadados
# Uso: ./forensic_scan.sh [email] [termo_de_busca]
# Ex:  ./forensic_scan.sh atendimento@ideiasblah.com.br "augusto joão"
#===============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

EMAIL="${1:-}"
TERMO="${2:-}"
DATA_INI="2026-05-01"
DATA_FIM="2026-06-01"
REPORT="forensic_report_$(date '+%Y%m%d_%H%M%S').txt"
TMPDB="/tmp/forensic_scan_$$"

cleanup() { rm -f "${TMPDB}"*; }
trap cleanup EXIT

log()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
err()    { echo -e "${RED}[x]${NC} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}==== $* ====${NC}\n"; }
sec()    { echo -e "\n${BOLD}--- $* ---${NC}"; }
section() { sec "$@"; }

H="$HOME"

# ====================================================
# 1. Screenshots
# ====================================================
scan_screenshots() {
    header "[1/6] Screenshots / Prints com 'facebook' no nome"
    for dir in "$H/Pictures" "$H/Imagens" "$H/Desktop" "$H/Área de Trabalho" \
               "$H/Downloads" "$H/Screenshots" "$H/ad-bot/screenshots"; do
        [ -d "$dir" ] || continue
        find "$dir" -maxdepth 3 \( -iname "*facebook*" -o -iname "*fb*" -o -iname "*meta*" \) \
            \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.gif" \) \
            -printf '%T@ %p %s\n' 2>/dev/null | sort -rn 2>/dev/null | head -20 | while read -r ts path size; do
            [ -n "$ts" ] || continue
            data=$(date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "?")
            echo "  $data | $(numfmt --to=iec "$size" 2>/dev/null || echo "$size B") | $path"
        done
    done
    log "Varredura de screenshots concluída"
}

# ====================================================
# 2. Downloads
# ====================================================
scan_downloads() {
    header "[2/6] Downloads ($DATA_INI a $DATA_FIM)"
    local d="$H/Downloads"
    [ -d "$d" ] || { warn "  ~/Downloads não encontrado"; return; }
    find "$d" -maxdepth 2 -newer "$(date -d "$DATA_INI" '+%Y%m%d%H%M.%S' 2>/dev/null)" \
        ! -newer "$(date -d "$DATA_FIM" '+%Y%m%d%H%M.%S' 2>/dev/null)" \
        -printf '%T@ %p %s\n' 2>/dev/null | sort -rn 2>/dev/null | while read -r ts path size; do
        [ -n "$ts" ] || continue
        data=$(date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "?")
        echo "  $data | $(numfmt --to=iec "$size" 2>/dev/null || echo "$size B") | $path"
    done
    log "Downloads per ${DATA_INI} a ${DATA_FIM} - concluído"
}

# ====================================================
# 3. Chrome
# ====================================================
query_chrome() {
    local db="$1" label="$2" like="$3"
    [ -f "$db" ] || return
    cp "$db" "${TMPDB}_chrome" 2>/dev/null || return
    sqlite3 "${TMPDB}_chrome" \
        "SELECT datetime(last_visit_time/1000000-11644473600,'unixepoch','localtime') as t, url
         FROM urls WHERE url LIKE '%${like}%'
           AND last_visit_time >= (strftime('%s','$DATA_INI','utc')+11644473600)*1000000
           AND last_visit_time < (strftime('%s','$DATA_FIM','utc')+11644473600)*1000000
         ORDER BY last_visit_time DESC LIMIT 30;" 2>/dev/null || true
}

get_profile_name() {
    local pref="$1/Preferences"
    python3 -c "
import json
try:
    with open('$pref') as f:
        d = json.load(f)
    name = d.get('profile',{}).get('name','')
    accts = [a.get('email','') for a in d.get('account_info',[])]
    print(f'{name} [{', '.join(accts)}]')
except: print('$1')
" 2>/dev/null
}

scan_chrome() {
    header "[3/6] Google Chrome"
    local base="$H/.config/google-chrome"
    [ -d "$base" ] || { warn "  Chrome não encontrado"; return; }

    sec "Perfis"
    for p in "$base"/Profile*/Preferences "$base"/Default/Preferences; do
        [ -f "$p" ] || continue
        echo "  $(dirname "$p" | xargs basename): $(get_profile_name "$(dirname "$p")")"
    done

    sec "Histórico Facebook por perfil"
    for p in "$base"/Profile* "$base"/Default; do
        [ -d "$p" ] || continue
        prof=$(basename "$p")
        res=$(query_chrome "$p/History" "$prof" "facebook")
        if [ -n "$res" ]; then
            echo "  [$prof] $(get_profile_name "$p")"
            echo "$res"
        fi
    done

    if [ -n "$EMAIL" ]; then
        sec "Busca por email '${EMAIL}' nas URLs"
        local esc=$(echo "$EMAIL" | sed 's/@/%40/g')
        for p in "$base"/Profile* "$base"/Default; do
            [ -d "$p" ] || continue
            db="$p/History"; [ -f "$db" ] || continue
            cp "$db" "${TMPDB}_chemail" 2>/dev/null || continue
            res=$(sqlite3 "${TMPDB}_chemail" \
                "SELECT datetime(last_visit_time/1000000-11644473600,'unixepoch','localtime') as t, url
                 FROM urls WHERE url LIKE '%$esc%' ORDER BY last_visit_time DESC LIMIT 10;" 2>/dev/null)
            if [ -n "$res" ]; then
                echo "  [$(get_profile_name "$p")]"
                echo "$res" | while IFS='|' read -r t url; do echo "    $t | $url"; done
            fi
        done
    fi

    if [ -n "$TERMO" ]; then
        sec "Busca por termo '${TERMO}' nas URLs"
        local termo_clean=$(echo "$TERMO" | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null || echo "$TERMO")
        for p in "$base"/Profile* "$base"/Default; do
            [ -d "$p" ] || continue
            db="$p/History"; [ -f "$db" ] || continue
            cp "$db" "${TMPDB}_cheterm" 2>/dev/null || continue
            res=$(sqlite3 "${TMPDB}_cheterm" \
                "SELECT datetime(last_visit_time/1000000-11644473600,'unixepoch','localtime') as t, url
                 FROM urls WHERE url LIKE '%$(echo "$TERMO" | sed 's/ /%/g')%'
                    OR url LIKE '%$(echo "$termo_clean" | sed 's/ /%/g')%'
                 ORDER BY last_visit_time DESC LIMIT 20;" 2>/dev/null)
            if [ -n "$res" ]; then
                echo "  [$(get_profile_name "$p")]"
                echo "$res" | while IFS='|' read -r t url; do echo "    $t | $url"; done
            fi
        done
    fi
}

# ====================================================
# 4. Firefox
# ====================================================
scan_firefox() {
    header "[4/6] Mozilla Firefox"
    local base="$H/snap/firefox/common/.mozilla/firefox"
    [ -d "$base" ] || base="$H/.mozilla/firefox"
    [ -d "$base" ] || { warn "  Firefox não encontrado"; return; }

    sec "Perfis"
    [ -f "$base/profiles.ini" ] && grep -E "^Name=|^Path=" "$base/profiles.ini" 2>/dev/null | paste - - | sed 's/Name=/  Nome: /;s/Path=/\n    Path: /'

    sec "Histórico Facebook"
    for pdir in "$base"/*/; do
        db="${pdir}places.sqlite"; [ -f "$db" ] || continue
        prof=$(basename "$pdir")
        cp "$db" "${TMPDB}_fx" 2>/dev/null || continue
        res=$(sqlite3 "${TMPDB}_fx" \
            "SELECT datetime(visit_date/1000000,'unixepoch','localtime') as t, url
             FROM moz_places JOIN moz_historyvisits ON moz_places.id=moz_historyvisits.place_id
             WHERE url LIKE '%facebook%'
               AND visit_date >= strftime('%s','$DATA_INI','utc')*1000000
               AND visit_date < strftime('%s','$DATA_FIM','utc')*1000000
             ORDER BY visit_date DESC LIMIT 30;" 2>/dev/null)
        if [ -n "$res" ]; then
            echo "  [$prof]"
            echo "$res" | while IFS='|' read -r t url; do echo "    $t | $url"; done
        fi
    done

    sec "Logins Facebook salvos"
    python3 -c "
import json, datetime, os, glob
base = '$base'
for lf in glob.glob(os.path.join(base, '*', 'logins.json')):
    prof = os.path.basename(os.path.dirname(lf))
    try:
        with open(lf) as f:
            data = json.load(f)
        for login in data.get('logins', []):
            hu = login.get('hostname', '')
            tl = login.get('timeLastUsed', 0)
            tc = login.get('timeCreated', 0)
            if 'facebook' in hu.lower():
                tl_str = datetime.datetime.fromtimestamp(tl / 1000).strftime('%Y-%m-%d %H:%M:%S') if tl else 'N/A'
                tc_str = datetime.datetime.fromtimestamp(tc / 1000).strftime('%Y-%m-%d %H:%M:%S') if tc else 'N/A'
                print(f'  [{prof}]')
                print(f'    Host: {hu}')
                print(f'    Criado: {tc_str} | Último uso: {tl_str}')
    except Exception as e:
        pass
" 2>/dev/null
}

# ====================================================
# 5. Brave
# ====================================================
scan_brave() {
    header "[5/6] Brave Browser"
    local base
    for d in "$H"/snap/brave/*/.config/BraveSoftware/Brave-Browser; do
        [ -d "$d" ] && base="$d" && break
    done
    [[ -z "${base:-}" ]] && { warn "  Brave não encontrado"; return; }

    sec "Histórico Facebook"
    for p in "$base"/Profile* "$base"/Default; do
        [ -d "$p" ] || continue
        prof=$(basename "$p"); db="$p/History"; [ -f "$db" ] || continue
        cp "$db" "${TMPDB}_br" 2>/dev/null || continue
        res=$(sqlite3 "${TMPDB}_br" \
            "SELECT datetime(last_visit_time/1000000-11644473600,'unixepoch','localtime') as t, url
             FROM urls WHERE url LIKE '%facebook%'
               AND last_visit_time >= (strftime('%s','$DATA_INI','utc')+11644473600)*1000000
               AND last_visit_time < (strftime('%s','$DATA_FIM','utc')+11644473600)*1000000
             ORDER BY last_visit_time DESC LIMIT 10;" 2>/dev/null)
        if [ -n "$res" ]; then
            echo "  [$prof]"
            echo "$res" | while IFS='|' read -r t url; do echo "    $t | $url"; done
        fi
    done
}

# ====================================================
# 6. Login Data (senhas salvas Chrome)
# ====================================================
scan_logins() {
    header "[6/6] Senhas Salvas Chrome (Login Data)"
    local base="$H/.config/google-chrome"
    [ -d "$base" ] || return

    sec "Facebook logins - último uso por perfil"
    for p in "$base"/Profile* "$base"/Default; do
        db="$p/Login Data"; [ -f "$db" ] || continue
        cp "$db" "${TMPDB}_login" 2>/dev/null || continue
        res=$(sqlite3 "${TMPDB}_login" \
            "SELECT origin_url, username_value,
                    datetime(date_last_used/1000000-11644473600,'unixepoch','localtime') as last_used
             FROM logins WHERE origin_url LIKE '%facebook%'
             ORDER BY date_last_used DESC LIMIT 10;" 2>/dev/null)
        if [ -n "$res" ]; then
            echo "  [$(get_profile_name "$p")]"
            echo "$res" | while IFS='|' read -r url user last; do
                echo "    $last | $user | $url"
            done
        fi
        if [ -n "$EMAIL" ]; then
            res2=$(sqlite3 "${TMPDB}_login" \
                "SELECT origin_url, datetime(date_last_used/1000000-11644473600,'unixepoch','localtime') as last_used
                 FROM logins WHERE username_value='$EMAIL' AND origin_url LIKE '%facebook%'
                 ORDER BY date_last_used DESC LIMIT 5;" 2>/dev/null)
            if [ -n "$res2" ]; then
                echo "  ⭐ Email '$EMAIL' encontrado! (últimos usos):"
                echo "$res2" | while IFS='|' read -r url last; do
                    echo "    $last | $url"
                done
            fi
        fi
    done
}

# ====================================================
# Extra: busca em arquivos
# ====================================================
scan_files() {
    [ -z "$TERMO" ] && return
    header "[Extra] Busca por '${TERMO}' em arquivos"
    local clean=$(echo "$TERMO" | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null || echo "$TERMO")
    local term_path=$(echo "$TERMO" | tr ' ' '*')

    sec "No nome do arquivo"
    find "$H" -maxdepth 8 -iname "*${term_path}*" 2>/dev/null | head -20

    sec "No conteúdo (txt, md, html, csv, json, log)"
    grep -rli "$TERMO\|$clean" "$H" \
        --include="*.txt" --include="*.md" --include="*.html" \
        --include="*.csv" --include="*.json" --include="*.log" --include="*.xml" \
        2>/dev/null | head -20
}

# ====================================================
# Main
# ====================================================
main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║      VARREdura Forense - Navegadores & Logs      ║"
    echo "╚══════════════════════════════════════════════════╝${NC}"
    echo "  Alvo: $USER@$(hostname)"
    echo "  Home: $H"
    echo "  Período: $DATA_INI a $DATA_FIM"
    [ -n "$EMAIL" ] && echo "  Email: $EMAIL"
    [ -n "$TERMO" ] && echo "  Termo: $TERMO"
    echo ""

    {
        scan_screenshots
        scan_downloads
        scan_chrome
        scan_firefox
        scan_brave
        scan_logins
        scan_files

        echo ""
        header "[FIM] Relatório salvo em: $REPORT"
    } 2>&1 | tee "$REPORT"
}

main "$@"
