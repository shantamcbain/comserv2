#!/bin/bash
# Self-test for .gitleaks.toml credential rules. Uses FAKE values only.
# Every "must catch" shape has to fire in .tt, .md, .pl and .sh files (docs included);
# every "must ignore" line is a placeholder that must NOT fire.
# Usage: Comserv/script/git/test_gitleaks_rules.sh   (run from the repo root)
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
ROOT="$(git rev-parse --show-toplevel)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
F='Ab3dK9xQm+T#'
mkdir -p "$T/Comserv/root/Documentation/system" "$T/src"
CATCH=(
  "  --from-literal=password='$F' \\"
  "password='$F'"
  "password=\"$F\""
  "password: $F"
  "DB_PASSWORD=$F"
  "mysql -u app -p'$F' -h db"
  "\$dsn = \"mysql://app:$F@db:3306/x\";"
  "my \$c = { password => '$F' };"
)
IGNORE=(
  'my $pw = '"'"'placeholder1234'"'"';'
  "password='<DB_PASSWORD from ~/.comserv/secrets>'"
  'password='"'"'$ENV{DB_PASS}'"'"
  'password: ${DB_PASSWORD}'
  "mysql -u app -p'<DB_PASSWORD from ~/.comserv/secrets>' -h db"
)
for ext in tt md pl sh; do
  d="$T/src"; [ "$ext" = tt ] && d="$T/Comserv/root/Documentation/system"
  printf '%s\n' "${CATCH[@]}"  > "$d/catch.$ext"
  printf '%s\n' "${IGNORE[@]}" > "$d/ignore.$ext"
done
gitleaks detect --no-git --redact --no-banner -c "$ROOT/.gitleaks.toml" --source "$T" \
  -f json -r "$T/r.json" >/dev/null 2>&1
rc=$?
[ "$rc" -le 1 ] || { echo "FAIL: gitleaks error (exit $rc)"; exit 1; }
fail=0
for ext in tt md pl sh; do
  for i in "${!CATCH[@]}"; do
    n=$((i+1))
    perl -MJSON::PP -0777 -e '
      my ($ext,$n)=@ARGV; my $d=decode_json(<STDIN>||"[]");
      exit((grep { $_->{File}=~/catch\.\Q$ext\E$/ && $_->{StartLine}==$n } @$d) ? 0 : 1)' "$ext" "$n" < "$T/r.json" \
      || { echo "FAIL: not caught: catch.$ext line $n"; fail=1; }
  done
  if perl -MJSON::PP -0777 -e 'my $e=shift; my $d=decode_json(<STDIN>||"[]"); exit((grep { $_->{File}=~/ignore\.\Q$e\E$/ } @$d) ? 0 : 1)' "$ext" < "$T/r.json"; then
    echo "FAIL: false positive in ignore.$ext"; fail=1
  fi
done
[ "$fail" = 0 ] && echo "gitleaks rule self-test: OK" || exit 1
