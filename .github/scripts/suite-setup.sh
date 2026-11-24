#!/usr/bin/env bash
# Put the ZIP tools tests/harness.roc needs on a bare GitHub runner.
# suite.yml hands this to bash, so it cannot be a .roc script.
set -euo pipefail

case "$(uname -s)" in
  Linux)
    # The Ubuntu image ships unzip and 7z but not libarchive's tar.
    sudo apt-get update -qq
    sudo apt-get install -y -qq libarchive-tools
    command -v bsdtar > /dev/null
    ;;
  Darwin)
    # bsdtar, unzip and 7z are all on the macOS image already.
    command -v bsdtar > /dev/null
    ;;
  *)
    # Windows ships libarchive's tar as tar.exe. Cmd spawns bsdtar by name and
    # CreateProcess only resolves .exe, so a copy under that name is what
    # makes it reachable. RUNNER_TEMP is a backslash path here, and the PATH
    # entry takes effect from the next step on.
    dest="${RUNNER_TEMP//\\//}/bsdtar"
    mkdir -p "$dest"
    cp /c/Windows/System32/tar.exe "$dest/bsdtar.exe"
    echo "$dest" >> "$GITHUB_PATH"
    ;;
esac

command -v unzip > /dev/null
command -v 7z > /dev/null
echo "unzip, bsdtar and 7z are available"

# Info-ZIP's zip writes the links tests/harness.roc reads back. Windows skips
# that check, since it makes no links without privileges.
case "$(uname -s)" in
  Linux | Darwin)
    command -v zip > /dev/null || { sudo apt-get install -y -qq zip && command -v zip > /dev/null; }
    echo "zip is available"
    ;;
esac
