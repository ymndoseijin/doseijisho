# 土星辞書 Doseijisho

![Image of Doseijisho, showing the result for the word 前. Multiple dictionaries seen to the right, such as Daijirin](https://i.imgur.com/0y2obbT.png)

## Description

Doseijisho is a new multilingual dictionary GUI program made in Zig. Currently, it supports StarDict, EPWING and TAB formats. In it, you can load multiple dictionaries. Still quite a WIP, I'll tidy things up soon enough.

It uses [MeCab](https://taku910.github.io/mecab/) for converting phrases into 分かち, separating them into words, making it possible to serach using entire phrases (like in [Jotoba](https://jotoba.de/)). That, besides personal amusement, is mostly the reason I made this, for I couldn't find a good desktop dictionary that could do that, that and Linux's dictionary software is quite lacking.

## Installation

Doseijisho has an AppImage on its [release page](https://github.com/ymndoseijin/doseijisho/releases), you may choose to install it that way. Currently, it's not in any package managers.

## Build instructions

Doseijisho's dependencies are `gtk4`, `MeCab` and `libeb`. Plus it's written in Zig, on Arch Linux (similarly enough on other *NIX systems) these can be installed by:

```
# pacman -S gtk4
$ yay -S mecab mecab-ipadict libeb // or manually or using any other AUR helper
$ yay -S zig-dev-bin // this is the current zig version I'm using, not sure if it works on other ones
```

Then, you can simply clone the repository and run `zig build run` to start the program. The binary is currently in `zig-out/bin/doseijisho`.
For common usage, I recommend using `zig build -Drelease-fast=true` instead. When debugging, it's better to disable it.

## Usage

```
doseijisho [options] ... [dictionary] [search-queries] ...

[dictionary] sets the target dictionary for search in the cli interface
[search-queries] sets the search words to the target dictionary, it can take more than one word.

If no [search-queries] are set, it will read from stdin by default. If [dictionary] and [search-queries] aren't set, it will trigger the GTK interface.

  -h --help shows this menu
  -s --stardict [stardict-file] sets StarDict dictionary
  -t --tab [tab-file] sets tabulated dictionary
  -e --epwing [eb-file] sets EB(EPWING, EBG...) dictionary
  -l --list list dictionary titles (separated by newlines)
  -v --verbose enable verbose output (useful for debugging)
  -c --cli-only disable all other interfaces besides cli
```

For example:
```
doseijisho -e ~/docs/dict/Daijirin -e ~/docs/dict/Kenkyusha_Waei_Daijiten_V5 -s /home/saturnian/docs/dict/stardict-kanjidic2-2.4.2/ -s ~/docs/dict/stardict-jmdict-ja-en-2.4.2/ -s ~/docs/dict/stardict-latin-english-2.4.2/ -s ~/docs/dict/stardict-enamdict-2.4.2
```

For the cli:
```
doseijisho -e ~/docs/dict/Daijirin -e ~/docs/dict/Kenkyusha_Waei_Daijiten_V5 -c "研究社　新和英大辞典　第５版" "優しい"

優しい:
やさしい２【優しい】 <?>(yasashii)
〔柔和な〕 gentle; tender; soft; meek; 〔優雅な〕 graceful; delicate; 〔愛情ある〕 affectionate; sweet; 〔温和な〕 mild(-mannered); 〔親切
  〕 kind(hearted); kindly; 〔温順な〕 suave; quiet; 〔人当たりのよい〕 amiable; sweet.
...
```

For other examples on the cli interface, you may look at the scripts on the root of the repository.
