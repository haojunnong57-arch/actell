#!/usr/bin/env bash
# Sourced by native tests. GNU ld options are unavailable on Darwin.
host_no_pie=(-fPIE) # Keep nonempty for macOS Bash 3.2 + nounset.
if [[ "$(uname -s)" != Darwin ]]; then host_no_pie=(-fno-pie -no-pie); fi
