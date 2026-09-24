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

SUBSCRIPTION_DEFAULT_MODEL="claude-sonnet-4-6"

# Every key this arm may write. run.sh --reset clears them all so switching providers is clean.
# shellcheck disable=SC2034  # consumed by run.sh --reset
SUBSCRIPTION_KEYS=(CLAUDE_CODE_OAUTH_TOKEN)

provider_subscription_configure() {
  local token model
  if [ "$NONINTERACTIVE" != 1 ] && [ -z "$F_SUBSCRIPTION_TOKEN" ] && [ -z "$(getenv CLAUDE_CODE_OAUTH_TOKEN)" ]; then
    cat >&2 <<'TXT'

  The agent embeds the Claude Code CLI, so it can run on your Claude Code subscription
  instead of a separately-billed API key. Usage counts against your own Claude Code
  limits, which makes this a local-development choice: the token authenticates as you.

  Mint one on THIS machine (it opens a browser, so it cannot be done from inside the
  dev kit), then paste it below:

      claude setup-token

  That returns a long-lived token beginning sk-ant-oat01-. It is not the same as the
  short-lived credential in your OS keychain, which expires in hours.

TXT
  fi

  token="$F_SUBSCRIPTION_TOKEN"; [ -z "$token" ] && token="$(getenv CLAUDE_CODE_OAUTH_TOKEN)"
  if [ -z "$token" ]; then
    [ "$NONINTERACTIVE" = 1 ] && { echo "Missing subscription token — pass --subscription-token <token> (non-interactive), or run 'claude setup-token' to mint one." >&2; return 1; }
    read -rs -p "Claude Code subscription token (from 'claude setup-token'): " token; echo >&2
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

  model="$F_SUBSCRIPTION_MODEL"; [ -z "$model" ] && model="$(getenv CLAUDE_MODEL)"
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
  setenv ANTHROPIC_API_KEY ""    # load-bearing — see header
  setenv ANTHROPIC_BASE_URL ""   # load-bearing — see header

  # Same reason as the anthropic and gateway arms: the agent's title LLM is Bedrock-only and
  # needs a well-formed region to not crash-loop; with no AWS creds the title call no-ops, so
  # ticket titles are simply not generated on this path.
  [ -n "$(getenv AWS_REGION)" ] || setenv AWS_REGION "us-east-1"

  echo "    using your Claude Code subscription (model: $model)."
  echo "    note: ticket titles are not generated on this path — the title LLM is Bedrock-only."
  [ -z "$(getenv AWS_ACCESS_KEY_ID)" ] || echo "    note: AWS keys are still set in .env — harmless (this path never uses them), but ./run.sh --reset clears them if you'd rather they were gone."
}
