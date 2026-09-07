#! /bin/sh
#
# Convenience entry point: `./install.sh` from a fresh clone, instead of
# having to know it actually lives at bin/backmeup.install.sh.
#
MY_PATH="`dirname \"$0\"`"              # relative
MY_PATH="`( cd \"$MY_PATH\" && pwd )`"  # absolutized and normalized
if [ -z "$MY_PATH" ] ; then
  exit 1  # fail
fi
exec "${MY_PATH}/bin/backmeup.install.sh" "$@"
