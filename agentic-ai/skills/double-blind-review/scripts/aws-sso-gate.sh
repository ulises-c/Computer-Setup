# shellcheck shell=bash disable=SC2034
# Sourced by the seat adapters for Bedrock-billed runs. botocore renews the
# hourly SSO tokens itself, but nothing renews past the IAM Identity Center
# portal session end, so a seat that starts too close to it dies mid-review.

readonly AWS_SSO_GATE_REFUSED=5
readonly AWS_SSO_GATE_DEFAULT_BUDGET=2h

aws_sso_budget_valid() {
  [[ $1 =~ ^([0-9]+|([0-9]+[dhms])+)$ ]]
}

# aws_sso_gate TAG BUDGET [AWS_PROFILE]: returns only when the session outlasts BUDGET.
aws_sso_gate() {
  local tag=$1 budget=$2 profile=${3:-} msg rc
  local -a args=(--need "$budget")
  [[ -n $profile ]] && args+=(--profile "$profile")
  if ! command -v aws-sso-ttl >/dev/null 2>&1; then
    printf '%s: refused: aws-sso-ttl is not on PATH, so the AWS SSO session end cannot be checked; install aws-sso-ttl and put it on PATH\n' "$tag" >&2
    exit "$AWS_SSO_GATE_REFUSED"
  fi
  if msg=$(aws-sso-ttl "${args[@]}" 2>&1); then
    return 0
  else
    rc=$?
  fi
  printf '%s: refused by the AWS SSO preflight (--budget %s, aws-sso-ttl exit %s): %s\n' \
    "$tag" "$budget" "$rc" "$msg" >&2
  exit "$AWS_SSO_GATE_REFUSED"
}

# aws_sso_env_value FILE NAME: prints the last value FILE assigns to NAME.
# Returns 1 when FILE does not assign it, or assigns it an empty value.
aws_sso_env_value() {
  local file=$1 name=$2 line val="" re
  re="^[[:space:]]*(export[[:space:]]+)?${name}[[:space:]]*=(.*)$"
  [[ -r $file ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ $re ]] || continue
    val=${BASH_REMATCH[2]}
    val=${val//[[:space:]\"\']/}
  done <"$file"
  [[ -n $val ]] || return 1
  printf '%s\n' "$val"
}
