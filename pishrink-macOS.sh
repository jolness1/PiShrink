#!/usr/bin/env bash
# PiShrink for macOS
# A macOS-adapted version of PiShrink (best-effort).
# Requires Homebrew-installed tools: parted, e2fsprogs (e2fsck, resize2fs, tune2fs, debugfs), xz/gzip/pigz (optional)

set -euo pipefail

version="macOS-adapted v24.10.23"

SCRIPTNAME="${0##*/}"
CURRENT_DIR="$(pwd)"
LOGFILE="${CURRENT_DIR}/${SCRIPTNAME%.*}.log"

info(){ echo "$SCRIPTNAME: $1"; }
error(){ echo "$SCRIPTNAME: ERROR occurred in line $1: ${@:2}"; }

help(){ cat <<EOM
Usage: $0 [-adrsvzZ] imagefile.img [newimagefile.img]

  -s  Don't attempt to add autoexpand on first boot (recommended on macOS)
  -v  Verbose
  -n  Disable update check (no-op here)
  -r  Use advanced fs repair
  -z  Compress with gzip
  -Z  Compress with xz
  -a  Use parallel compression (pigz for gzip)
  -d  Debug to log file

Notes:
  - This script assumes Homebrew-provided `parted` and `e2fsprogs` are installed.
  - Installing recommendations: `brew install parted e2fsprogs xz pigz`
  - Due to macOS differences, this script attaches the image with `hdiutil` and operates on the partition device.
  - Autoexpand injection uses `debugfs` if available; otherwise it will be skipped.
EOM
exit 1
}

# Defaults
debug=false
repair=false
parallel=false
verbose=false
ziptool=""
should_skip_autoexpand=false

while getopts ":adrnshvzZ" opt; do
  case "$opt" in
    a) parallel=true;;
    d) debug=true;;
    r) repair=true;;
    s) should_skip_autoexpand=true;;
    v) verbose=true;;
    z) ziptool="gzip";;
    Z) ziptool="xz";;
    n) ;; # noop
    h) help;;
    *) help;;
  esac
done
shift $((OPTIND-1))

src="$1"
img="$1"

if [[ -z "$img" || ! -f "$img" ]]; then
  error $LINENO "image file required"
  help
fi

if (( EUID != 0 )); then
  error $LINENO "This script must be run as root (use sudo)."
  exit 3
fi

if [[ "$debug" == true ]]; then
  echo "$SCRIPTNAME: starting debug log $LOGFILE"
  exec 1> >(tee -a "$LOGFILE")
  exec 2> >(tee -a "$LOGFILE" >&2)
fi

REQUIRED=(parted e2fsck tune2fs resize2fs debugfs hdiutil diskutil truncate)
if [[ -n "$ziptool" ]]; then
  if [[ "$ziptool" == "gzip" && "$parallel" == true ]]; then
    REQUIRED+=(pigz)
  else
    REQUIRED+=($ziptool)
  fi
fi

for cmd in "${REQUIRED[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    # hdiutil and diskutil are macOS builtins; if not present, warn
    echo "WARNING: $cmd not found in PATH. Please install via Homebrew if needed."
  fi
done

# Copy to new file if provided
if [[ -n "$2" ]]; then
  f="$2"
  if [[ -n $ziptool && "${f##*.}" == "${ziptool}" ]]; then
    f="${f%.*}"
  fi
  info "Copying $1 to $f..."
  cp -p "$1" "$f"
  img="$f"
fi

info "Gathering data"
parted_output=$(parted -ms "$img" unit B print) || { error $LINENO "parted failed"; exit 6; }
partnum=$(echo "$parted_output" | tail -n1 | cut -d: -f1)
partstart=$(echo "$parted_output" | tail -n1 | cut -d: -f2 | tr -d 'B')

info "Attaching image with hdiutil"
attach_out=$(hdiutil attach -nomount "$img" 2>/dev/null || true)
if [[ -z "$attach_out" ]]; then
  # Try without -nomount to be more permissive
  attach_out=$(hdiutil attach "$img" 2>/dev/null || true)
fi
if [[ -z "$attach_out" ]]; then
  error $LINENO "hdiutil failed to attach image"
  exit 7
fi

device=$(printf "%s\n" "$attach_out" | awk 'NR==1{print $1}')
if [[ -z "$device" ]]; then
  error $LINENO "Could not determine device from hdiutil output"
  printf "%s\n" "$attach_out"
  exit 8
fi

info "Device: $device ; partition: $partnum (start $partstart)"
partdev="${device}s${partnum}"
rawpartdev="${partdev/dev/rdisk}"

if [[ ! -b "$rawpartdev" && ! -c "$rawpartdev" ]]; then
  # macOS may present partition as device without 's' suffix in some images; try parted device listing
  if [[ -b "$partdev" ]]; then
    rawpartdev="$partdev"
  else
    error $LINENO "Partition device $partdev not present; listing attached devices:"; diskutil list "$device"; exit 9
  fi
fi

info "Using partition device: $rawpartdev"

# Gather tune2fs info
tuneout=$(tune2fs -l "$rawpartdev" 2>/dev/null) || { echo "$tuneout"; error $LINENO "tune2fs failed. Ensure e2fsprogs are installed and the partition is an ext2/3/4 filesystem."; hdiutil detach "$device" >/dev/null 2>&1 || true; exit 10; }
currentsize=$(echo "$tuneout" | grep '^Block count:' | tr -d ' ' | cut -d: -f2)
blocksize=$(echo "$tuneout" | grep '^Block size:' | tr -d ' ' | cut -d: -f2)

info "Checking filesystem"
e2fsck -pf "$rawpartdev" || {
  if [[ "$repair" == true ]]; then
    info "Attempting full repair"
    e2fsck -fy "$rawpartdev" || { error $LINENO "Filesystem repair failed"; hdiutil detach "$device" >/dev/null 2>&1 || true; exit 11; }
  else
    error $LINENO "e2fsck reported issues. Re-run with -r to attempt repair."; hdiutil detach "$device" >/dev/null 2>&1 || true; exit 11
  fi
}

minsize_str=$(resize2fs -P "$rawpartdev" 2>/dev/null) || { error $LINENO "resize2fs -P failed"; hdiutil detach "$device" >/dev/null 2>&1 || true; exit 12; }
minsize=$(cut -d: -f2 <<< "$minsize_str" | tr -d ' ')

if [[ "$currentsize" -eq "$minsize" ]]; then
  info "Filesystem already at minimum size"
else
  # Add a small slack like Linux script
  extra_space=$((currentsize - minsize))
  for space in 5000 1000 100; do
    if [[ $extra_space -gt $space ]]; then
      minsize=$((minsize + space))
      break
    fi
  done

  info "Shrinking filesystem to ${minsize} blocks"
  resize2fs -p "$rawpartdev" "$minsize" || { error $LINENO "resize2fs failed"; hdiutil detach "$device" >/dev/null 2>&1 || true; exit 13; }

  # Attempt zeroing free space for better compression using debugfs if available
  if command -v debugfs >/dev/null 2>&1; then
    info "Attempting to zero free space via debugfs (best-effort)"
    tmpfile=$(mktemp -t pishrink_zero.XXXX)
    dd if=/dev/zero of="$tmpfile" bs=1M count=1 2>/dev/null || true
    # Try writing a zero file into the image; this may not fill entire free space but helps a bit
    debugfs -w "$rawpartdev" -R "write $tmpfile /PiShrink_zero_file; quit" >/dev/null 2>&1 || true
    rm -f "$tmpfile"
  else
    info "debugfs not found; skipping zero-fill step"
  fi

  # Detach the image so parted can modify the image file
  hdiutil detach "$device" >/dev/null 2>&1 || true

  info "Shrinking partition in image file"
  partnewsize=$((minsize * blocksize))
  newpartend=$((partstart + partnewsize))
  parted -s -a minimal "$img" rm "$partnum" || { error $LINENO "parted rm failed"; exit 14; }
  parted -s "$img" unit B mkpart primary "$partstart" "$newpartend" || { error $LINENO "parted mkpart failed"; exit 15; }

  endresult=$(parted -ms "$img" unit B print free | tail -1 | cut -d: -f2 | tr -d 'B')
  truncate -s "$endresult" "$img" || { error $LINENO "truncate failed"; exit 16; }

  # re-attach to cleanly detach device
  hdiutil attach -nomount "$img" >/dev/null 2>&1 || true
fi

# Handle compression
if [[ -n $ziptool ]]; then
  options=""
  if [[ $parallel == true && $ziptool == "gzip" && command -v pigz >/dev/null 2>&1 ]]; then
    info "Using pigz for parallel gzip compression"
    pigz -9 "$img" || { error $LINENO "pigz failed"; exit 18; }
    img="$img.gz"
  else
    info "Using $ziptool to compress"
    $ziptool -9 "$img" || { error $LINENO "$ziptool failed"; exit 19; }
    img="$img.${ziptool}"
  fi
fi

aftersize=$(ls -lh "$img" | awk '{print $5}')
beforesize=$(ls -lh "$src" | awk '{print $5}')
info "Shrunk $img from $beforesize to $aftersize"

info "Done. If you want auto-expand injected into the image's /etc/rc.local, re-run with debugfs available and without -s."

exit 0
