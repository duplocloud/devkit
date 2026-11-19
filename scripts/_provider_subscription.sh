# shellcheck shell=bash
# Sourced by run.sh — the `subscription` LLM provider arm: run the agent on a Claude Code
# subscription token instead of a per-token API key, so ticket work and local extension
# development bill to the same place.
#
# WHY a separate file: like the gateway arm, this one has a prompt, validation and a
# load-bearing set of blanks, which is more than the two-line inline arms carry. Expects the
# caller to define getenv/setenv, NONINTERACTIVE and the F_SUBSCRIPTION_* flag variables.
#
# Where the token comes from: `claude setup-token` on the developer's own machine (it needs a
# browser, so it cannot be done from here). That is a long-lived token intended for handing to
# a headless environment — not the short-lived access token in the OS keychain.
#
# How the agent picks this path (core/agent_setup/llm_provider.py in
# claude-code-generic-ai-agent): CLAUDE_CODE_OAUTH_TOKEN set, and every provider above it in
# the precedence chain unset. Subscription auth sits LAST, just ahead of the Bedrock fallback,
# so that a token exported in someone's shell can never silently displace a deliberately
# configured provider. The flip side is that this arm has to clear the two keys the dev kit
# itself can set — ANTHROPIC_API_KEY and ANTHROPIC_BASE_URL — or they would win the chain and
# the token would never be reached. Same load-bearing blanking as bedrock-instance-role's AWS
# keys and gateway's ANTHROPIC_API_KEY, and for the same reason.
#
# This is for local development. The token authenticates as one person against their own
# subscription, so it does not belong in a shared or deployed stack.

SUBSCRIPTION_DEFAULT_MODEL="claude-sonnet-5-5"
# Earlier values of SUBSCRIPTION_DEFAULT_MODEL (space-separated). An existing .env still holding one
# of these is upgraded to the current default; see provider_subscription_configure.
SUBSCRIPTION_PREVIOUS_DEFAULTS="claude-sonnet-5"
# Registered alongside the default so the ticket LLM picker offers both. Bare ids, same as the
# `anthropic` arm: this path is the first-party API, which is exactly what those ids name.
SUBSCRIPTION_EXTRA_MODELS="claude-opus-5-5"

# Strip leading/trailing whitespace from a pasted token. Normalization, NOT validation: no valid
# opaque bearer token has whitespace at its edges, so this cannot turn away a good token whatever
# shape tokens take next. Deliberately no length or stricter format check here — per the header,
# the token's shape is not a documented contract, and rejecting a valid future token with a
# confident error message would be worse than the 401 it was meant to prevent.
_subscription_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Every key this arm may write. run.sh --reset clears them all so switching providers is clean.
# shellcheck disable=SC2034  # consumed by run.sh --reset
SUBSCRIPTION_KEYS=(CLAUDE_CODE_OAUTH_TOKEN)

provider_subscription_configure() {
  local token model
  if [ "$NONINTERACTIVE" != 1 ] && [ -z "$F_SUBSCRIPTION_TOKEN" ] && [ -z "$(getenv CLAUDE_CODE_OAUTH_TOKEN)" ]; then
    # Keep this short: the user has already chosen this path from the menu, so the rationale is
    # settled — all they need now is the command to run and what to paste back.
    cat >&2 <<'TXT'

  Run the following command in another terminal:

      claude setup-token

  That returns a long-lived token beginning sk-ant-oat01- — copy it and paste it below.

TXT
  fi

  token="$(_subscription_trim "$F_SUBSCRIPTION_TOKEN")"
  [ -z "$token" ] && token="$(_subscription_trim "$(getenv CLAUDE_CODE_OAUTH_TOKEN)")"
  if [ -z "$token" ]; then
    [ "$NONINTERACTIVE" = 1 ] && { echo "Missing subscription token — pass --subscription-token <token> (non-interactive), or run 'claude setup-token' to mint one." >&2; return 1; }
    read -rs -p "Claude Code subscription token (from 'claude setup-token'): " token; echo >&2
    token="$(_subscription_trim "$token")"
  fi
  [ -n "$token" ] || { echo "No subscription token given — run 'claude setup-token' to mint one." >&2; return 1; }
  # Warn rather than reject: the prefix is not a documented contract, so a future token shape
  # should not be turned away by the dev kit. An API key pasted here IS worth catching, though —
  # it would otherwise be sent as a bearer token and fail with a puzzling 401.
  case "$token" in
    sk-ant-oat*) ;;
    sk-ant-api*) echo "    note: that looks like an Anthropic API key (sk-ant-api…), not a subscription token. Use ./run.sh --model anthropic for a key, or run 'claude setup-token' for a token." >&2 ;;
    *)           echo "    note: expected a token beginning sk-ant-oat… — continuing anyway, but check it came from 'claude setup-token'." >&2 ;;
  esac

  model="$F_SUBSCRIPTION_MODEL"
  if [ -z "$model" ]; then
    model="$(getenv CLAUDE_MODEL)"
    # Unlike the anthropic/bedrock arms, this one keeps the .env model across runs, so a bumped
    # default would never reach an existing install. A value equal to a previous default is ours,
    # not the user's choice: move it to the current default. Anything else (or an explicit
    # --subscription-model, even an old default) is a deliberate pick and is kept.
    # Plain string equality per entry — no glob matching — so a hand-edited value containing *, ? or [
    # can only ever equal itself, never match a previous default by accident.
    for prev in $SUBSCRIPTION_PREVIOUS_DEFAULTS; do
      if [ "$model" = "$prev" ]; then
        echo "    note: CLAUDE_MODEL was the previous default '$model' — moving to $SUBSCRIPTION_DEFAULT_MODEL." >&2
        model="$SUBSCRIPTION_DEFAULT_MODEL"; break
      fi
    done
  fi
  [ -n "$model" ] || model="$SUBSCRIPTION_DEFAULT_MODEL"
  # A model id carried over from another provider — a Bedrock inference-profile id or a gateway's
  # namespaced id — is rejected outright by the first-party API. Fall back rather than fail on
  # someone else's leftovers.
  case "$model" in
    us.*|global.*|*.anthropic.*)
      echo "    note: CLAUDE_MODEL was '$model' (a Bedrock inference-profile id, which the first-party API rejects) — using $SUBSCRIPTION_DEFAULT_MODEL instead." >&2
      model="$SUBSCRIPTION_DEFAULT_MODEL" ;;
    */*)
      echo "    note: CLAUDE_MODEL was '$model' (a gateway-namespaced id, which the first-party API rejects) — using $SUBSCRIPTION_DEFAULT_MODEL instead." >&2
      model="$SUBSCRIPTION_DEFAULT_MODEL" ;;
  esac

  setenv CLAUDE_CODE_OAUTH_TOKEN "$token"
  setenv CLAUDE_MODEL "$model"
  # Registration-only extras: what the ticket LLM picker offers next to CLAUDE_MODEL. Overwritten
  # rather than appended to, because a leftover us.anthropic.* / gateway-namespaced id from a
  # previous provider would be rejected by the first-party API exactly as CLAUDE_MODEL is above.
  setenv CLAUDE_EXTRA_MODELS "$SUBSCRIPTION_EXTRA_MODELS"
  setenv ANTHROPIC_API_KEY ""    # load-bearing — see header
  setenv ANTHROPIC_BASE_URL ""   # load-bearing — see header

  # Same reason as the anthropic and gateway arms: the agent's title LLM is Bedrock-only and
  # needs a well-formed region to not crash-loop; with no AWS creds the title call no-ops, so
  # ticket titles are simply not generated on this path.
  [ -n "$(getenv AWS_REGION)" ] || setenv AWS_REGION "us-east-1"

  # The blanks above only reach .env. docker compose resolves ${VAR:-} from the calling shell
  # BEFORE .env, so a key exported there still lands in the agent and wins the precedence chain —
  # silently, since the agent then just runs on it. Neither script sources .env, so anything
  # visible here came from the user's shell. Unset them in this process (this file is sourced, so
  # that is the calling script, never the user's shell) so the compose calls that follow are correct.
  #
  # Silent by choice. This does NOT cover a later manual `docker compose up` from the same shell,
  # which still sees the export and would hand it to the agent in place of the subscription token —
  # a wrong-provider run with no error, just an unexpected bill.
  local shadow="" k
  for k in ANTHROPIC_API_KEY ANTHROPIC_BASE_URL; do
    [ -n "${!k-}" ] && shadow="$shadow $k"
  done
  # shellcheck disable=SC2086  # word-split on purpose: one name per word
  [ -n "$shadow" ] && unset $shadow

  echo "    using your Claude Code subscription (model: $model)."
  [ -z "$(getenv AWS_ACCESS_KEY_ID)" ] || echo "    note: AWS keys are still set in .env — harmless (this path never uses them), but ./run.sh --reset clears them if you'd rather they were gone."
}
