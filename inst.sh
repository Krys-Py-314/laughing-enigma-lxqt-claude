#!/bin/bash
sudo /bin/cp -f ./enigma_bashrc $HOME/.bashrc
./01_enigma_inst-lowmem-lxqt-rpi5.sh
./02_enigma_inst_dark_theme_and_icons.v2.sh
./03_enigma_hide_qterminal_drop.sh
./04_enigma_conf_featherpad.sh
./05_enigma_conf_pcmanfm-qt.sh
./06_enigma_conf_qterminal.sh
./07_enigma_conf_lxqt_panel_left.sh
./08_enigma_conf_add-cputemp.sh
./10_enigma_lgpio-setup.sh
