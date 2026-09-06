#!/bin/sh
# CI entry point: run the bmu regression test suite.
# (Kept under the historical name referenced by .travis.yml.)
sh "`dirname \"$0\"`/tests/test_backmeup.sh"
