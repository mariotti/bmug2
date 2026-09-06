#!/bin/sh
# See: http://stackoverflow.com/questions/20449707/using-travis-ci-for-testing-on-unix-shell-scripts

testEquality() {
	assertEquals 1 1
}

. ./tests/shunit2

