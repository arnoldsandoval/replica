#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'Usage: %s <new-repository-directory>\n' "$0" >&2
  exit 2
fi

parent="$(dirname "$1")"
if [[ ! -d "$parent" ]]; then
  printf 'Destination must have an existing parent directory.\n' >&2
  exit 1
fi
if [[ -e "$1" || -L "$1" ]]; then
  printf 'Destination already exists: %s\n' "$1" >&2
  exit 1
fi

for tool in curl tar git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Replica setup requires %s.\n' "$tool" >&2
    exit 1
  fi
done

temporary="$(mktemp -d "${TMPDIR:-/tmp}/replica-download.XXXXXX")"
trap 'rm -r -- "$temporary"' EXIT

archive="$temporary/replica.tar.gz"
if ! curl -q -fLSs --output "$archive" \
    'https://github.com/github/replica/archive/refs/heads/main.tar.gz'; then
  printf 'Could not download the Replica source archive. Check your network connection and access to GitHub, then try again.\n' >&2
  exit 1
fi
if ! tar -tzf "$archive" > "$temporary/members" ||
    ! tar -tvzf "$archive" > "$temporary/types"; then
  printf 'Could not read the Replica source archive.\n' >&2
  exit 1
fi

archive_root="replica-main"
has_script=0
has_skills=0
has_templates=0
exec 3< "$temporary/types"
while IFS= read -r member; do
  if ! IFS= read -r details <&3; then
    printf 'Replica source archive has an invalid listing.\n' >&2
    exit 1
  fi
  relative="${member#"$archive_root/"}"
  if [[ "$member" != "$archive_root/" &&
        ( "$member" != "$archive_root/"* || -z "$relative" ||
          "$relative" == /* || "$relative" == *"//"* ||
          "/$relative/" == *"/../"* || "/$relative/" == *"/./"* ||
          "$relative" == *$'\r'* || "$relative" == *$'\t'* ) ]]; then
    printf 'Replica source archive contains an unsafe path: %s\n' "$member" >&2
    exit 1
  fi
  if [[ "$member" == "$archive_root/" ||
        "$member" == "$archive_root/starter" ||
        "$member" == "$archive_root/starter/"* ||
        "$member" == "$archive_root/scripts" ||
        "$member" == "$archive_root/scripts/" ||
        "$member" == "$archive_root/scripts/create-prototype-repo.sh" ]]; then
    if [[ "$member" == */ ]]; then
      if [[ "$details" != d* ]]; then
        printf 'Replica source archive contains an unsupported directory: %s\n' "$member" >&2
        exit 1
      fi
    elif [[ "$details" != -* ]]; then
      printf 'Replica source archive contains a linked or unsupported file: %s\n' "$member" >&2
      exit 1
    fi
  fi
  case "$member" in
    "$archive_root/scripts/create-prototype-repo.sh") has_script=1 ;;
    "$archive_root/starter/.agents/skills/setup-skills/SKILL.md") has_skills=1 ;;
    "$archive_root/starter/.agents/context-templates/SKILL.md") has_templates=1 ;;
  esac
  if [[ "$member" == "$archive_root/starter/.git" ||
        "$member" == "$archive_root/starter/.git/"* ]]; then
    printf 'Replica source archive contains Git metadata.\n' >&2
    exit 1
  fi
done < "$temporary/members"
if IFS= read -r <&3; then
  printf 'Replica source archive has an invalid listing.\n' >&2
  exit 1
fi
exec 3<&-
if [[ $has_script -ne 1 || $has_skills -ne 1 || $has_templates -ne 1 ]]; then
  printf 'Replica source archive is missing the starter or setup script.\n' >&2
  exit 1
fi

if ! tar -xzf "$archive" -C "$temporary" \
    "$archive_root/starter" "$archive_root/scripts/create-prototype-repo.sh"; then
  printf 'Could not extract the Replica starter.\n' >&2
  exit 1
fi
if [[ ! -f "$temporary/$archive_root/scripts/create-prototype-repo.sh" ||
      -L "$temporary/$archive_root/scripts/create-prototype-repo.sh" ]]; then
  printf 'Replica source archive contains an invalid setup script.\n' >&2
  exit 1
fi
bash "$temporary/$archive_root/scripts/create-prototype-repo.sh" "$1"
