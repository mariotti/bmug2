# INSTALL

Get a copy of the code. For example:

 - mkdir ~/bmu
 - cd ~/bmu
 - git clone https://github.com/mariotti/bmu

Run the install script:

  - ./bmu/bin/backmeup.install.sh
  - answer to questions
  - You are done!

# QUESTIONS EXPLAINED

You will get these questions:

## Please type the SYNC directory:
 - default: (/Users/<username>/tmp/rsyncBackup)

This is the directory which will contain the "sync" of your project or backed up directory. It is typically
on an external disk. It is a copy of your data at the time you did run the last time the backmeup.sh command.

 - type [ENTER]
    -- Input is not a dir
    -- not valid or not existing SYNC directory: /Users/<username>/tmp/rsyncBackup
    -- Shall I create the directory for you (y/N)?
 - type [y]
    -- SYNC Directory is: /Users/<username>/tmp/rsyncBackup

## Please type the BackUp directory:
 - Default: (/Users/<username>/tmp/rsyncBackup-BP)

This is the "backup" directory. Old versions are stored here.

Input is not a dir
not valid or not existing BackUp directory: /Users/<username>/tmp/rsyncBackup-BP
Shall I create the directory for you (y/N)?
y
BackUp Directory is: /Users/<username>/tmp/rsyncBackup-BP

## Please type the IndexDB directory:
 - Default: (/Users/<username>/tmp/rsyncBackup/.locate.dir)

Input is not a dir
not valid or not existing IndexDB directory: /Users/<username>/tmp/rsyncBackup/.locate.dir
Shall I create the directory for you (y/N)?
y
IndexDB Directory is: /Users/<username>/tmp/rsyncBackup/.locate.dir

## Please type the base INSTALL directory:
 - Default: (/Users/<username>/usr)

Install on: /Users/<username>/usr
## Please type the BMU install directory: (/Users/<username>/usr/bmu)

Input is not a dir
not valid or not existing BMU install directory: /Users/<username>/usr/bmu
Shall I create the directory for you (y/N)?
y
BMU install Directory is: /Users/<username>/usr/bmu

