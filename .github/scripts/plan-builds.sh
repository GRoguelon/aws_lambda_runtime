#!/usr/bin/env bash
#
# Works out which Docker images (and Erlang layer releases) are missing:
#
#   - lambda-layer-erlang:<otp> for the latest Erlang/OTP patch of every major
#     >= OTP_MIN_MAJOR, along with its erlang-<otp> GitHub release;
#   - lambda-layer-elixir:<elixir>-erlang-<otp> for the latest Elixir patch of
#     every minor >= ELIXIR_MIN_MINOR that Hex has built for that OTP major.
#
# REBUILD=true lists every tracked version, published or not.
#
# Writes `erlang` (["29.1.2", ...]) and `elixir` ([{"elixir": "1.20.5",
# "otp": "29.1.2"}, ...]) to stdout, and to $GITHUB_OUTPUT on GitHub Actions.

set -euo pipefail

OTP_MIN_MAJOR=${OTP_MIN_MAJOR:-29}
ELIXIR_MIN_MINOR=${ELIXIR_MIN_MINOR:-1.20}
REBUILD=${REBUILD:-false}
REPOSITORY=${GITHUB_REPOSITORY:-GRoguelon/aws_lambda_runtime}
REGISTRY_NAMESPACE=groguelon

github_api() {
  curl -fsSL \
    -H 'Accept: application/vnd.github+json' \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    "https://api.github.com/$1"
}

# Stable OTP releases whose source tarball has been uploaded.
otp_versions() {
  local page=1 body
  while body=$(github_api "repos/erlang/otp/releases?per_page=100&page=$page") &&
    [ "$(jq length <<<"$body")" -gt 0 ]; do
    jq -r '
      .[]
      | select((.draft or .prerelease) | not)
      | (.tag_name | ltrimstr("OTP-")) as $v
      | select($v | test("^[0-9]+(\\.[0-9]+)*$"))
      | select(any(.assets[]; .name == "otp_src_\($v).tar.gz"))
      | $v' <<<"$body"
    page=$((page + 1))
  done
}

# Latest OTP patch of each tracked major, one per line.
latest_otp_versions() {
  otp_versions | sort -V |
    awk -F. -v min="$OTP_MIN_MAJOR" '
      $1 >= min { latest[$1] = $0 }
      END { for (major in latest) print latest[major] }' |
    sort -V
}

# "<otp major> <elixir version>" for every stable Elixir build on Hex.
elixir_builds() {
  curl -fsSL https://builds.hex.pm/builds/elixir/builds.txt |
    awk '{ print $1 }' |
    sed -nE 's/^v([0-9]+\.[0-9]+\.[0-9]+)-otp-([0-9]+)$/\2 \1/p'
}

# Latest Elixir patch of each tracked minor built for the given OTP major.
latest_elixir_versions() {
  local otp_major=$1

  awk -v major="$otp_major" '$1 == major { print $2 }' <<<"$ELIXIR_BUILDS" |
    sort -V |
    awk -F. -v min="$ELIXIR_MIN_MINOR" '
      BEGIN { split(min, m, ".") }
      $1 > m[1] || ($1 == m[1] && $2 >= m[2]) { latest[$1 "." $2] = $0 }
      END { for (minor in latest) print latest[minor] }' |
    sort -V
}

declare -A REGISTRY_TOKENS

# Whether the multi-arch tag exists (it's only created once both
# architectures have been pushed, so a half-done build gets retried).
image_exists() {
  local repository=$1 tag=$2 status

  [ "$REBUILD" = true ] && return 1

  if [ -z "${REGISTRY_TOKENS[$repository]:-}" ]; then
    REGISTRY_TOKENS[$repository]=$(
      curl -fsSL \
        ${GITHUB_TOKEN:+-u "${GITHUB_ACTOR:-github}:$GITHUB_TOKEN"} \
        "https://ghcr.io/token?scope=repository:$REGISTRY_NAMESPACE/$repository:pull" |
        jq -er .token
    ) || {
      echo "ghcr.io refused a pull token for $repository; check this repository has access to the package" >&2
      exit 1
    }
  fi

  status=$(curl -sS -o /dev/null -w '%{http_code}' --head \
    -H "Authorization: Bearer ${REGISTRY_TOKENS[$repository]}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://ghcr.io/v2/$REGISTRY_NAMESPACE/$repository/manifests/$tag")

  case "$status" in
    200) return 0 ;;
    404) return 1 ;;
    *)
      echo "ghcr.io answered $status for $repository:$tag" >&2
      exit 1
      ;;
  esac
}

release_exists() {
  local status

  status=$(curl -sS -o /dev/null -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    "https://api.github.com/repos/$REPOSITORY/releases/tags/$1")

  case "$status" in
    200) return 0 ;;
    404) return 1 ;;
    *)
      echo "GitHub answered $status for release $1" >&2
      exit 1
      ;;
  esac
}

ELIXIR_BUILDS=$(elixir_builds)
erlang=()
elixir=()

for otp in $(latest_otp_versions); do
  if ! image_exists lambda-layer-erlang "$otp" || ! release_exists "erlang-$otp"; then
    erlang+=("$otp")
  fi

  for ex in $(latest_elixir_versions "${otp%%.*}"); do
    if ! image_exists lambda-layer-elixir "$ex-erlang-$otp"; then
      elixir+=("$ex $otp")
    fi
  done
done

erlang_json=$(printf '%s\n' "${erlang[@]}" | jq -Rnc '[inputs | select(length > 0)]')
elixir_json=$(printf '%s\n' "${elixir[@]}" |
  jq -Rnc '[inputs | select(length > 0) | split(" ") | {elixir: .[0], otp: .[1]}]')

{
  echo "erlang=$erlang_json"
  echo "elixir=$elixir_json"
} | tee -a "${GITHUB_OUTPUT:-/dev/null}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Images to build"
    echo
    jq -r 'if length == 0 then "- Erlang: none" else .[] | "- Erlang \(.)" end' <<<"$erlang_json"
    jq -r 'if length == 0 then "- Elixir: none" else .[] | "- Elixir \(.elixir) / Erlang \(.otp)" end' <<<"$elixir_json"
  } >>"$GITHUB_STEP_SUMMARY"
fi
