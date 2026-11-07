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
command="sh -c "a=\$(head -1 /proc/stat); sleep 1; b=\$(head -1 /proc/stat); echo \"\$a \$b\" | awk '{i1=\$5; t1=\$2+\$3+\$4+\$5+\$6+\$7+\$8; i2=\$16; t2=\$12+\$13+\$14+\$15+\$16+\$17+\$18; printf \"CPU:%.0f%%\", 100*(1-(i2-i1)/(t2-t1))}'""
repeat=true
repeatTimer=5
runOnStartup=true
text=CPU %1
type=customcommand
EOF

nohup lxqt-panel >/dev/null 2>&1 &
