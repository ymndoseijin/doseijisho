#!/bin/sh

DICTIONARY=$(doseijisho $@ -l -c | dmenu)

ENTRY=$(zenity --entry)
doseijisho $@ -c "$DICTIONARY" "$ENTRY" | zenity --text-info --title Query
