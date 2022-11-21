#!/bin/sh
DICTIONARY=$(doseijisho $@ -l -c | dmenu)

notify-send "Query" "$(dmenu < /dev/null | doseijisho $@ -c $DICTIONARY)"
