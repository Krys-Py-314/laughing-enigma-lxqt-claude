#!/usr/bin/env bash
#
# enigma_conf_lxqt_panel.sh
#
# Sets the LXQt Fancy Menu option "Categories Position" to Left
# (Fancy Menu Settings > Categories Position), renames and reorders some menu
# entries, on Debian Trixie / Raspberry Pi 5. With the classic Application
# Menu (mainmenu) on the panel everything but the categories position applies.
#
#     chmod +x enigma_conf_lxqt_panel.sh
#     ./enigma_conf_lxqt_panel.sh                   # categories left + renames
#     ./enigma_conf_lxqt_panel.sh --right           # categories back on the right
#     ./enigma_conf_lxqt_panel.sh --no-rename       # only move the categories
#     ./enigma_conf_lxqt_panel.sh --restore-names   # undo the renames only
#     ./enigma_conf_lxqt_panel.sh --no-order        # leave the menu order alone
#     ./enigma_conf_lxqt_panel.sh --default-order   # back to the stock menu order
#
# Renamed entries:
#     Accessories  : FeatherPad              -> Text Editor (Featherpad)
#     Accessories  : LXQt File Archiver      -> File Archiver (LXQt File Archiver)
#     Accessories  : PCManFM-Qt File Manager -> File Manager (PCManFM-Qt)
#     Internet     : vimb                    -> Web Browser (vimb)
#     System Tools : QTerminal               -> Terminal (QTerminal)
#
# Moved entries (done together with the renames):
#     Terminal (QTerminal) : System Tools -> Accessories. The stock menu keeps
#         anything in the System category out of Accessories, so the entry
#         cannot be in both.
#     Web Browser (vimb)   : also listed under Accessories (stays in Internet).
#
# Order of Accessories: Terminal, File Manager, Text Editor, Web Browser,
#     then everything else alphabetically.
#
# Quick Launch icons of renamed apps show the new label as tooltip.
#
# Also removes the Pi-Apps launcher icon from the desktop (Pi-Apps itself and
# its menu entry stay).
#
# How it works:
#     Menu labels come from the Name= line of each app's .desktop file in
#     /usr/share/applications. Those files are NOT edited (the next apt
#     upgrade would put them back). A copy with the new Name= is written to
#     ~/.local/share/applications/, which the menu reads first. The
#     translated Name[xx]= lines are dropped from the copy, otherwise a
#     non-English locale would still show the old label. Apps that are not
#     installed are skipped.
#
#     The settings dialog stores the choice in ~/.config/lxqt/panel.conf as
#     categoriesAtRight=<bool> inside every plugin section with
#     type=fancymenu (false = Left, true or missing = Right). This script
#     sets that key in each such section and leaves the rest of the file as
#     it is. A dated backup of panel.conf is kept next to it.
#
#     The menu order needs a <Layout> in the menu definition. The system
#     file under /etc/xdg/menus is not edited: a copy with the layout goes to
#     ~/.config/menus/, and menu_file=<that copy> is set in every menu
#     widget section, fancymenu or mainmenu (the panel does not look in ~/.config/menus by
#     itself). --default-order removes both again.
#
#     lxqt-panel writes panel.conf back when it exits, so a running panel is
#     stopped first, the file is edited, and the panel is started again.
#
# Environment overrides:
#     ASSUME_YES=1      never prompt (non-interactive)
#

set -uo pipefail

# ---------------------------------------------------------------------------
# Colors for output
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    print_error "Please do not run this script as root. Run as your normal desktop user."
    exit 1
fi

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/lxqt"
PANEL="${CONF_DIR}/panel.conf"
SYS_PANEL="/etc/xdg/lxqt/panel.conf"
ASSUME_YES="${ASSUME_YES:-0}"
VALUE="false"
SIDE="Left"
DO_POSITION=1
DO_RENAME=1
RESTORE_NAMES=0
REMOVED_IDS=()
ORDER="custom"          # custom | keep | default
USER_MENU_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/menus"
MENU_MARKER="enigma_conf_lxqt_panel.sh: Accessories order"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
MARKER="X-Renamed-By=enigma_conf_lxqt_panel.sh"

# desktop file IDs to try | program in Exec= (fallback search) | new label
#   | categories to add | categories to remove   (both space-separated, optional)
RENAMES=(
    "featherpad.desktop org.featherpad.FeatherPad.desktop|featherpad|Text Editor (Featherpad)||"
    "lxqt-archiver.desktop org.lxqt.lxqt-archiver.desktop|lxqt-archiver|File Archiver (LXQt File Archiver)||"
    "pcmanfm-qt.desktop org.lxqt.pcmanfm-qt.desktop|pcmanfm-qt|File Manager (PCManFM-Qt)||"
    "vimb.desktop|vimb|Web Browser (vimb)|Utility|"
    "qterminal.desktop org.lxqt.qterminal.desktop|qterminal|Terminal (QTerminal)|Utility|System"
)

# First entries of the Accessories category, in this order (programs from the
# table above); everything else follows alphabetically.
ACCESSORIES_ORDER=(qterminal pcmanfm-qt featherpad vimb)

usage() {
    sed -n '11,17p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
        --right)   VALUE="true"; SIDE="Right" ;;
        --left)    VALUE="false"; SIDE="Left" ;;
        --no-rename)     DO_RENAME=0 ;;
        --no-order)      ORDER="keep" ;;
        --default-order) ORDER="default" ;;
        --restore-names) RESTORE_NAMES=1; DO_RENAME=0; DO_POSITION=0; ORDER="keep" ;;
        -h|--help) usage; exit 0 ;;
        *)         print_error "Unknown option: $arg"; usage; exit 1 ;;
    esac
done

confirm() {
    local prompt="$1"
    [ "$ASSUME_YES" = "1" ] && return 0
    [ -t 0 ] || return 0
    local reply=""
    read -r -p "$(echo -e "${YELLOW}[WARN]${NC} ${prompt} [Y/n] ")" reply
    case "$reply" in
        [nN]*) return 1 ;;
        *)     return 0 ;;
    esac
}

# Names of the panel.conf sections of a plugin type: plugin_sections FILE TYPE
plugin_sections() {
    awk -v t="$2" '
        /^\[.*\][ \t]*$/ { sec = substr($0, 2, index($0, "]") - 2); next }
        sec != "" && /^[ \t]*type[ \t]*=/ {
            v = $0; sub(/^[ \t]*type[ \t]*=[ \t]*/, "", v); sub(/[ \t]*$/, "", v)
            if (v == t) print sec
        }
    ' "$1"
}

# SECTIONS: Fancy Menu sections (they take categoriesAtRight).
# MENU_SECTIONS: every menu widget, Fancy Menu and the classic Application
# Menu alike (they take menu_file, which carries the Accessories order).
read_menu_sections() {
    mapfile -t SECTIONS < <(plugin_sections "$PANEL" fancymenu)
    mapfile -t MAIN_SECTIONS < <(plugin_sections "$PANEL" mainmenu)
    MENU_SECTIONS=("${SECTIONS[@]}" "${MAIN_SECTIONS[@]}")
    mapfile -t QL_SECTIONS < <(plugin_sections "$PANEL" quicklaunch)
    # --restore-names only puts the Quick Launch entries back.
    [ "$DO_POSITION" = "1" ] || SECTIONS=()
}

# Prints the system .desktop file for an app: first by file ID, then by
# searching for a [Desktop Entry] whose Exec= runs the program with nothing
# but a %-field code after it (so "qterminal --drop" is not picked).
find_source() {
    local ids="$1" bin="$2" dir id f
    local IFS_SAVE="$IFS"
    IFS=':'
    local dirs=(${XDG_DATA_DIRS:-/usr/local/share:/usr/share})
    IFS="$IFS_SAVE"
    for id in $ids; do
        for dir in "${dirs[@]}"; do
            f="${dir}/applications/${id}"
            [ -f "$f" ] && { printf '%s' "$f"; return 0; }
        done
    done
    for dir in "${dirs[@]}"; do
        for f in "${dir}"/applications/*.desktop; do
            [ -f "$f" ] || continue
            awk -v bin="$bin" '
                /^\[/ { main = ($0 == "[Desktop Entry]"); next }
                main && /^Exec=/ {
                    sub(/^Exec=/, ""); n = split($0, w, /[ \t]+/)
                    p = w[1]; sub(/.*\//, "", p)
                    if (p == bin && (n == 1 || (n == 2 && w[2] ~ /^%[a-zA-Z]$/))) found = 1
                }
                END { exit !found }
            ' "$f" && { printf '%s' "$f"; return 0; }
        done
    done
    return 1
}

refresh_menu_cache() {
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
    fi
    # Touching the directory wakes the panel's file watcher so the menu
    # rebuilds itself without a restart.
    touch "$APPS_DIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Menu labels
# ---------------------------------------------------------------------------
if [ "$RESTORE_NAMES" = "1" ]; then
    print_status "Restoring the original menu labels..."
    restored=0
    for dest in "$APPS_DIR"/*.desktop; do
        [ -f "$dest" ] && grep -qx "$MARKER" "$dest" || continue
        if [ -f "${dest}.before-rename" ]; then
            mv -f -- "${dest}.before-rename" "$dest"
        else
            rm -f -- "$dest"
            REMOVED_IDS+=("$(basename -- "$dest")")
        fi
        print_status "Restored $(basename -- "$dest")"
        restored=1
    done
    [ "$restored" = "1" ] || print_status "No renamed entries found - nothing to restore."
    refresh_menu_cache
    # Quick Launch entries pointing at a copy that is gone now have to go
    # back to the system launcher; that is done with the panel.conf edit below.
    { [ "${#REMOVED_IDS[@]}" -gt 0 ] && [ -f "$PANEL" ]; } || exit 0
fi

if [ "$DO_RENAME" = "1" ]; then
    print_status "Renaming menu entries..."
    mkdir -p -- "$APPS_DIR" || { print_error "Could not create ${APPS_DIR}"; exit 1; }
    for spec in "${RENAMES[@]}"; do
        IFS='|' read -r ids bin label addcats delcats <<<"$spec"
        if ! src="$(find_source "$ids" "$bin")"; then
            print_warning "${bin} is not installed - skipped \"${label}\"."
            continue
        fi
        id="$(basename -- "$src")"
        dest="${APPS_DIR}/${id}"
        base="$src"
        if [ -f "$dest" ] && ! grep -qx "$MARKER" "$dest"; then
            # A user copy made by something else: keep its other changes and
            # save it so --restore-names can put it back.
            cp -p -- "$dest" "${dest}.before-rename"
            base="${dest}.before-rename"
        elif [ -f "${dest}.before-rename" ]; then
            base="${dest}.before-rename"
        fi
        tmp="$(mktemp "${dest}.XXXXXX")" || { print_error "mktemp failed"; exit 1; }
        # New Categories= value, only when this entry changes category:
        # the current list minus $delcats, plus $addcats where missing.
        newcats=""
        if [ -n "${addcats}${delcats}" ]; then
            newcats="$(awk -v add="$addcats" -v del="$delcats" '
                /^\[/ { main = ($0 == "[Desktop Entry]"); next }
                main && /^Categories[ \t]*=/ { sub(/^Categories[ \t]*=[ \t]*/, ""); cats = $0 }
                END {
                    nd = split(del, d, " "); for (i = 1; i <= nd; i++) drop[d[i]] = 1
                    n = split(cats, c, ";"); out = ""
                    for (i = 1; i <= n; i++)
                        if (c[i] != "" && !(c[i] in drop) && !(c[i] in have)) { have[c[i]] = 1; out = out c[i] ";" }
                    na = split(add, a, " ")
                    for (i = 1; i <= na; i++)
                        if (!(a[i] in have)) { have[a[i]] = 1; out = out a[i] ";" }
                    print out
                }
            ' "$base")"
        fi
        # Inside [Desktop Entry]: replace Name=, drop Name[xx]=, add a marker,
        # and replace Categories= when a new value was worked out above.
        # [Desktop Action ...] sections keep their own Name= lines.
        awk -v label="$label" -v marker="$MARKER" -v cats="$newcats" '
            /^\[/ {
                main = ($0 == "[Desktop Entry]")
                print
                if (main) {
                    print "Name=" label; print marker
                    if (cats != "") print "Categories=" cats
                }
                next
            }
            main && /^(Name(\[[^]]*\])?|X-Renamed-By)[ \t]*=/ { next }
            main && cats != "" && /^Categories[ \t]*=/ { next }
            { print }
        ' "$base" >"$tmp"
        if ! grep -qx "Name=${label}" "$tmp"; then
            rm -f -- "$tmp"
            print_warning "Could not build a renamed copy of ${src} - skipped."
            continue
        fi
        chmod 0644 "$tmp"
        mv -f -- "$tmp" "$dest"
        print_status "${id}: \"${label}\"${newcats:+  [Categories=${newcats}]}"
    done
    refresh_menu_cache
fi

# ---------------------------------------------------------------------------
# Pi-Apps desktop icon
# ---------------------------------------------------------------------------
# The Pi-Apps installer drops a launcher on the desktop. Only that launcher is
# removed; ~/pi-apps and the menu entry are left alone.
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null)" || DESKTOP_DIR=""
[ -n "$DESKTOP_DIR" ] && [ "$DESKTOP_DIR" != "$HOME" ] || DESKTOP_DIR="$HOME/Desktop"
PIAPPS_ICON="${DESKTOP_DIR}/pi-apps.desktop"
if [ "$RESTORE_NAMES" != "1" ] && [ -f "$PIAPPS_ICON" ] && grep -q '^Exec=.*pi-apps' "$PIAPPS_ICON"; then
    if rm -f -- "$PIAPPS_ICON"; then
        print_status "Removed the Pi-Apps desktop icon (${PIAPPS_ICON})."
    else
        print_warning "Could not remove ${PIAPPS_ICON}."
    fi
fi

[ "$DO_POSITION" = "1" ] || [ "$RESTORE_NAMES" = "1" ] || exit 0

# ---------------------------------------------------------------------------
# Find panel.conf
# ---------------------------------------------------------------------------

if [ ! -f "$PANEL" ]; then
    if [ -f "$SYS_PANEL" ]; then
        # The panel would do the same on its first save: start from the
        # system default and keep the user's copy from then on.
        mkdir -p -- "$CONF_DIR" || { print_error "Could not create ${CONF_DIR}"; exit 1; }
        cp -- "$SYS_PANEL" "$PANEL" || { print_error "Could not copy ${SYS_PANEL}"; exit 1; }
        print_status "No user panel.conf yet; started from ${SYS_PANEL}."
    else
        print_error "Neither ${PANEL} nor ${SYS_PANEL} exists."
        print_error "Start LXQt once (so the panel writes its config), then run this again."
        exit 1
    fi
fi

read_menu_sections
if [ "$RESTORE_NAMES" = "1" ]; then
    :
elif [ "${#MENU_SECTIONS[@]}" -eq 0 ]; then
    print_error "No menu widget (Fancy Menu or Application Menu) found in ${PANEL}."
    exit 1
elif [ "${#SECTIONS[@]}" -gt 0 ]; then
    print_status "Fancy Menu section(s): ${SECTIONS[*]} - categories go to the ${SIDE}."
else
    print_status "The panel uses the classic Application Menu (${MAIN_SECTIONS[*]}); it has no"
    print_status "\"Categories Position\" option, so only the menu order is set."
fi

# ---------------------------------------------------------------------------
# Stop the panel so it cannot overwrite the edit when it exits
# ---------------------------------------------------------------------------
PANEL_WAS_RUNNING=0
if pgrep -u "$(id -u)" -x lxqt-panel >/dev/null 2>&1; then
    PANEL_WAS_RUNNING=1
    print_status "Stopping lxqt-panel..."
    pkill -u "$(id -u)" -x lxqt-panel >/dev/null 2>&1
    for _ in $(seq 1 50); do
        pgrep -u "$(id -u)" -x lxqt-panel >/dev/null 2>&1 || break
        sleep 0.1
    done
    if pgrep -u "$(id -u)" -x lxqt-panel >/dev/null 2>&1; then
        print_error "lxqt-panel did not stop; nothing was changed."
        exit 1
    fi
    # The panel may have written a fresh copy on exit; re-read it.
    read_menu_sections
fi

# ---------------------------------------------------------------------------
# Edit panel.conf
# ---------------------------------------------------------------------------
BACKUP="${PANEL}.bak.$(date +%Y%m%d-%H%M%S)"
cp -p -- "$PANEL" "$BACKUP" && print_status "Backup: ${BACKUP}"

# ---------------------------------------------------------------------------
# Order of the Accessories category
# ---------------------------------------------------------------------------
# MENU_ACTION says what happens to menu_file= in the menu widget sections:
#   keep  - untouched            set - point it at MENU_DEST
#   unset - remove it (only when it points into ~/.config/menus)
MENU_ACTION="keep"
MENU_DEST=""

# menu_file= of the first menu widget (empty when not set).
CUR_MENU="$(awk -v s="${MENU_SECTIONS[0]:-}" '
    /^\[.*\][ \t]*$/ { sec = substr($0, 2, index($0, "]") - 2); next }
    sec == s && /^[ \t]*menu_file[ \t]*=/ { sub(/^[ \t]*menu_file[ \t]*=[ \t]*/, ""); print; exit }
' "$PANEL")"

# The system menu definition the panel would use by itself.
find_system_menu() {
    local name dir
    local IFS_SAVE="$IFS"
    IFS=':'
    local dirs=(${XDG_CONFIG_DIRS:-} /etc/xdg /etc /usr/share)
    IFS="$IFS_SAVE"
    for name in "$@"; do
        [ -n "$name" ] || continue
        for dir in "${dirs[@]}"; do
            [ -n "$dir" ] || continue
            [ -f "${dir}/menus/${name}" ] && { printf '%s' "${dir}/menus/${name}"; return 0; }
        done
    done
    return 1
}

if [ "$ORDER" = "custom" ]; then
    MENU_SRC=""
    case "$CUR_MENU" in
        "${USER_MENU_DIR}"/*) ;;                       # our own copy: look up the system one
        /*) [ -f "$CUR_MENU" ] && MENU_SRC="$CUR_MENU" ;;
    esac
    if [ -z "$MENU_SRC" ]; then
        # Without menu_file the Fancy Menu reads lxqt-panel-applications.menu
        # and the classic menu lxqt-applications.menu.
        if [ "${#SECTIONS[@]}" -gt 0 ]; then
            MENU_SRC="$(find_system_menu "${CUR_MENU##*/}" lxqt-panel-applications.menu lxqt-applications.menu)" || MENU_SRC=""
        else
            MENU_SRC="$(find_system_menu "${CUR_MENU##*/}" lxqt-applications.menu lxqt-panel-applications.menu)" || MENU_SRC=""
        fi
    fi

    # .desktop file names of the installed apps, in the wanted order.
    ORDER_IDS=()
    for bin in "${ACCESSORIES_ORDER[@]}"; do
        for spec in "${RENAMES[@]}"; do
            IFS='|' read -r ids sbin _ <<<"$spec"
            [ "$sbin" = "$bin" ] || continue
            if src="$(find_source "$ids" "$bin")"; then
                ORDER_IDS+=("$(basename -- "$src")")
            fi
        done
    done

    if [ -z "$MENU_SRC" ]; then
        print_warning "No LXQt menu definition found under /etc/xdg/menus - menu order unchanged."
    elif [ "${#ORDER_IDS[@]}" -eq 0 ]; then
        print_warning "None of the apps to order are installed - menu order unchanged."
    else
        MENU_DEST="${USER_MENU_DIR}/$(basename -- "$MENU_SRC")"
        mkdir -p -- "$USER_MENU_DIR"
        MENU_TMP="$(mktemp "${MENU_DEST}.XXXXXX")" || { print_error "mktemp failed"; exit 1; }
        # Copy the system file and put a <Layout> just before the closing
        # </Menu> of the Accessories menu.
        awk -v ids="$(printf '%s\n' "${ORDER_IDS[@]}")" -v marker="$MENU_MARKER" '
            inacc && /<Menu>/ { depth++ }
            inacc && /<\/Menu>/ {
                if (depth == 0) {
                    print "\t\t<!-- " marker " -->"
                    print "\t\t<Layout>"
                    n = split(ids, a, "\n")
                    for (i = 1; i <= n; i++) if (a[i] != "") print "\t\t\t<Filename>" a[i] "</Filename>"
                    print "\t\t\t<Merge type=\"menus\"/>"
                    print "\t\t\t<Merge type=\"files\"/>"
                    print "\t\t</Layout>"
                    inacc = 0
                } else depth--
            }
            { print }
            /<Name>[ \t]*Accessories[ \t]*<\/Name>/ { inacc = 1; depth = 0 }
        ' "$MENU_SRC" >"$MENU_TMP"
        if grep -qF -- "$MENU_MARKER" "$MENU_TMP"; then
            chmod 0644 "$MENU_TMP"
            mv -f -- "$MENU_TMP" "$MENU_DEST"
            MENU_ACTION="set"
            print_status "Accessories order: ${ORDER_IDS[*]}"
            print_status "Menu definition: ${MENU_DEST} (from ${MENU_SRC})"
        else
            rm -f -- "$MENU_TMP"
            MENU_DEST=""
            print_warning "No Accessories menu in ${MENU_SRC} - menu order unchanged."
        fi
    fi
elif [ "$ORDER" = "default" ]; then
    case "$CUR_MENU" in
        "${USER_MENU_DIR}"/*)
            MENU_ACTION="unset"
            if [ -f "$CUR_MENU" ] && grep -qF -- "$MENU_MARKER" "$CUR_MENU"; then
                rm -f -- "$CUR_MENU"
            fi
            print_status "Menu order back to the stock definition."
            ;;
        *)  print_status "Menu order is already the stock one." ;;
    esac
fi

# ---------------------------------------------------------------------------
# Quick Launch tooltips
# ---------------------------------------------------------------------------
# A Quick Launch icon shows the Name= of the .desktop file its entry points
# at. Pointing the entry at the renamed copy in ~/.local/share/applications
# gives the tooltip the new label; --restore-names points it back at the
# system file. QL_MAP holds "file name <TAB> path to use" lines.
QL_MAP=""
if [ "$RESTORE_NAMES" = "1" ]; then
    for id in "${REMOVED_IDS[@]}"; do
        if src="$(find_source "$id" "-")"; then
            QL_MAP+="${id}"$'\t'"${src}"$'\n'
        fi
    done
elif [ "$DO_RENAME" = "1" ]; then
    for f in "$APPS_DIR"/*.desktop; do
        [ -f "$f" ] && grep -qx "$MARKER" "$f" || continue
        QL_MAP+="$(basename -- "$f")"$'\t'"${f}"$'\n'
    done
fi

TMP="$(mktemp "${PANEL}.XXXXXX")" || { print_error "mktemp failed"; exit 1; }
trap 'rm -f "$TMP"' EXIT

# In every fancymenu section: drop any existing categoriesAtRight line and
# write the new one directly under the section header. In every menu widget
# section (fancymenu and mainmenu): the same for menu_file, when it changes.
awk -v secs="$(printf '%s\n' "${SECTIONS[@]}")" -v val="$VALUE" \
    -v msecs="$(printf '%s\n' "${MENU_SECTIONS[@]}")" \
    -v maction="$MENU_ACTION" -v mfile="$MENU_DEST" \
    -v qsecs="$(printf '%s\n' "${QL_SECTIONS[@]}")" -v qmap="$QL_MAP" '
    BEGIN {
        n = split(qsecs, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") qwant[a[i]] = 1
        n = split(qmap, a, "\n")
        for (i = 1; i <= n; i++) { t = index(a[i], "\t"); if (t) qm[substr(a[i], 1, t - 1)] = substr(a[i], t + 1) }
        n = split(secs, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1
        n = split(msecs, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") mwant[a[i]] = 1
    }
    /^\[.*\][ \t]*$/ {
        sec = substr($0, 2, index($0, "]") - 2)
        print
        if (sec in want) print "categoriesAtRight=" val
        if ((sec in mwant) && maction == "set") print "menu_file=" mfile
        next
    }
    (sec in want) && /^[ \t]*categoriesAtRight[ \t]*=/ { next }
    (sec in mwant) && maction != "keep" && /^[ \t]*menu_file[ \t]*=/ { next }
    (sec in qwant) && /^apps\\[0-9]+\\desktop[ \t]*=/ {
        key = $0; sub(/[ \t]*=.*/, "", key)
        b = $0; sub(/^[^=]*=[ \t]*/, "", b); sub(/.*\//, "", b)
        if (b in qm) { print key "=" qm[b]; next }
    }
    { print }
' "$PANEL" >"$TMP"

# Sanity check before replacing the real file.
BAD=0
for s in "${SECTIONS[@]}"; do
    got="$(awk -v s="$s" '
        /^\[.*\][ \t]*$/ { sec = substr($0, 2, index($0, "]") - 2); next }
        sec == s && /^categoriesAtRight=/ { sub(/^categoriesAtRight=/, ""); print }
    ' "$TMP")"
    [ "$got" = "$VALUE" ] || BAD=1
done
if [ "$MENU_ACTION" = "set" ]; then
    for s in "${MENU_SECTIONS[@]}"; do
        got="$(awk -v s="$s" '
            /^\[.*\][ \t]*$/ { sec = substr($0, 2, index($0, "]") - 2); next }
            sec == s && /^menu_file=/ { sub(/^menu_file=/, ""); print }
        ' "$TMP")"
        [ "$got" = "$MENU_DEST" ] || BAD=1
    done
fi
if [ "$BAD" = "1" ] || [ ! -s "$TMP" ]; then
    print_error "Editing panel.conf failed; the original is unchanged."
    exit 1
fi



#$HOME/.config/lxqt//panel.conf
section="worldclock"
parameter="customFormat"
value="<span style=font-size:12pt;>hh:mm</span>"


configfile="$HOME/.config/lxqt/panel.conf"
configclock="$HOME/.config/lxqt/clock.conf"

crudini --del "$configfile" "$section"

cat >> "$configclock" <<EOF
[worldclock]
autoRotate=true
customFormat="'<b>'HH:mm:ss'</b><br/><font size=\"-2\">'ddd, d MMM yyyy'<br/>'TT'</font>'"
dateFormatType=custom
dateLongNames=false
datePadDay=false
datePosition=below
dateShowDoW=false
dateShowYear=false
defaultTimeZone=
formatType=short-timeonly
showDate=true
showTimezone=false
showTooltip=false
showWeekNumber=true
timeAMPM=false
timePadHour=false
timeShowSeconds=false
timeZones\size=0
timezoneFormatType=iana
timezonePosition=below
useAdvancedManualFormat=false
EOF

crudini  --merge "$configfile" < "$configclock" 

printf ".\n.\n"
print_status "Configuration of [ worldclock ] BEGIN..."
printf ".\n.\n"

crudini --set "$configfile" "$section" "$parameter" "$value"

printf ".\n.\n"
print_status "Configuration of [ worldclock ] END..."
printf ".\n.\n"

chmod --reference="$PANEL" "$TMP" 2>/dev/null || chmod 0644 "$TMP"
mv -f -- "$TMP" "$PANEL" || { print_error "Could not write ${PANEL}"; exit 1; }
trap - EXIT
if [ "${#SECTIONS[@]}" -gt 0 ]; then
    print_status "Set categoriesAtRight=${VALUE} in ${PANEL}"
fi
if [ "$MENU_ACTION" = "set" ]; then
    print_status "Set menu_file=${MENU_DEST} in ${PANEL}"
fi



# ---------------------------------------------------------------------------
# Start the panel again
# ---------------------------------------------------------------------------
if [ "$PANEL_WAS_RUNNING" = "1" ]; then
    # lxqt-session may restart the panel by itself; give it a moment.
    sleep 2
    if ! pgrep -u "$(id -u)" -x lxqt-panel >/dev/null 2>&1; then
        if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
            print_status "Starting lxqt-panel..."
            ( setsid lxqt-panel >/dev/null 2>&1 & ) || true
        else
            print_warning "No display found to restart lxqt-panel from here."
            print_warning "Log out and back in to get the panel back."
        fi
    fi
    print_status "Done. Open the menu to see the result."
else
    print_status "Done. The menu changes show the next time LXQt starts."
fi
