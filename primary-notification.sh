#!/bin/sh
notify-send "$(doseijisho -i -c "研究社　新和英大辞典　第５版" -e /home/saturnian/docs/dict/Kenkyusha_Waei_Daijiten_V5 "$(xclip -selection primary -o)" | awk -vRS='' 'NR==1')"
