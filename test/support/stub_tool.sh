#!/bin/sh
tool=$(basename "$0")
{
  printf '%s' "$tool"
  for arg in "$@"; do
    printf '\037%s' "$arg"
  done
  printf '\n'
} >> "$AC_TEST_STUB_LOG"

if [ "$AC_TEST_FAIL_TOOL" = "$tool" ]; then
  echo "$tool failed" >&2
  exit 1
fi

case "$tool" in
  aapt)
    if [ "$1" = "ls" ]; then
      printf '%b' "$AC_TEST_AAPT_LS"
    fi
    ;;
  zipalign)
    cp "$3" "$4"
    ;;
esac
exit 0
