#!/bin/bash
set -e
CONF="$HOME/.config/lxqt/panel.conf"
ID="customcommand_cputemp"

[ -f "$CONF" ] || { echo "No $CONF - start the panel once first"; exit 1; }
grep -q "^\[$ID\]" "$CONF" && { echo "Already added"; exit 0; }

pkill lxqt-panel || true
sleep 1
cp "$CONF" "$CONF.bak"

# append the widget to the panel's plugins list
sed -i "0,/^plugins=/s/^plugins=\(.*\)$/plugins=\1, $ID/" "$CONF"

# widget settings
cat >> "$CONF" <<EOF

[$ID]
alignment=Right
command="sh -c \"top -bn2 -d1 | grep 'Cpu(s)' | tail -1 | awk '{printf \\\"%.0f%%\\\", 100-\\$8}'\""
repeat=true
repeatTimer=5
runOnStartup=true
text=CPU %1
type=customcommand
EOF

nohup lxqt-panel >/dev/null 2>&1 &
