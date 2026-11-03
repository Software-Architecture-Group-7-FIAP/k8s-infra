#!/usr/bin/env bash
set -euo pipefail

readonly chart_version="8.0.39"
readonly expected_sha256="96eb019f7c78e1e746e0ba170b7e656e437ae3f7bfe7203f812e750511db108f"
readonly chart_dir="/tmp/auto-shop-newrelic-chart"
readonly chart_file="${chart_dir}/nri-bundle-${chart_version}.tgz"
readonly chart_url="https://github.com/newrelic/helm-charts/releases/download/nri-bundle-${chart_version}/nri-bundle-${chart_version}.tgz"

mkdir -p -- "${chart_dir}"
chmod 700 -- "${chart_dir}"
tmp_file="$(mktemp "${chart_dir}/nri-bundle.XXXXXX")"
trap 'rm -f -- "${tmp_file}"' EXIT

curl --fail --location --silent --show-error --retry 3   --output "${tmp_file}"   "${chart_url}"
if ! printf '%s  %s\n' "${expected_sha256}" "${tmp_file}" | sha256sum --check --status; then
  echo "::error::New Relic Helm chart checksum mismatch."
  exit 1
fi

chmod 600 -- "${tmp_file}"
mv -- "${tmp_file}" "${chart_file}"
trap - EXIT
