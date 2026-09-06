[![Stories in Ready](https://badge.waffle.io/mariotti/bmu.png?label=ready&title=Ready)](https://waffle.io/mariotti/bmu)
# WARNING this code is at GAMMA stage

Wrong settings can ovewrite your data.

# bmu

BackMeUp - A tool to make backups for personal use. Also system wide and embedded devices.

## How it currently works: we want to improve this

 - install: run backmeup.install.sh
 - backup: run backmeup.sh as many times as you need or set it on a cron job
 - index: run backmeup.updatedb.sh any now and then or setup a nightly cron job
 - search: run backmeup.locate.sh

## Target Requirements

  - A backup which is readable by "almost any" system. As a matter of facts the current backup system depends
    only on the backup device and not on the backup software. The basic software currently is "updatedb" and
    "locate" from the findutils package, which are widely available as default system software.
    There are plans to introduce additional (read to add on top of the current system) indexing software
    to improve the search.
    
  - A backup which I explore by simply listing files with "ls" or with any modern file manager.

## Why another backup tool?

I was, and I am still, not happy with all the tools around. Also lately I started to use a light mac machine
for quick everyday work. My current linux box is even lighter, and I use it for high load programming.
This made things even worst: sharing a personal backup system within OSs.

The Mac OS Time Machine was a nice discovery and finding that I can do the same with the
Unix command "rsync" was even better.

What I propose is something between a backup, a time machine and close to version control if you "control" it.

## Future directions

 - The first is indeed to make it stable and generally usable.
 - A GUI
 - An archive facility to compress very old data which will still include an indexing/search facility

# News

## Tested on linux

Finally I got back to my linux box and tested it!

I realised the problem is not linux or mac but more gnu version or mlocate.

This will need to create an other issue. gnu or m?
