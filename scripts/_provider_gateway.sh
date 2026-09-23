# shellcheck shell=bash
# Sourced by run.sh — the `gateway` LLM provider arm: any Anthropic-compatible endpoint
# (OpenRouter, Bifrost, LiteLLM, Snowflake Cortex, …) that holds the real provider credentials itself.
#
# WHY a separate file: the other provider arms are a handful of lines inline in run.sh; this one has
# prompts, validation and per-gateway knobs enough to be worth keeping out of the main flow, plus a test
# suite (tests/test-provider-gateway.sh) that sources it with stub .env helpers. Expects the caller to
# define getenv/setenv, NONINTERACTIVE and the F_GATEWAY_* flag variables.
#
# How the agent picks this path (core/agent_setup/llm_provider.py in claude-code-generic-ai-agent):
# ANTHROPIC_BASE_URL set AND ANTHROPIC_API_KEY empty. Key + URL together means "proxy in front of the
# real Anthropic API" — a different code path that would send the gateway's token nowhere useful — so
# blanking ANTHROPIC_API_KEY here is load-bearing, exactly like bedrock-instance-role blanks AWS keys.

GATEWAY_DEFAULT_MODEL="claude-sonnet-5"
# Context-window defaults, set on the gateway path ONLY. A gateway usually serves model ids the Claude
# CLI does not recognise, and an unrecognised id has no known context window: long sessions then hard-400
# instead of compacting. Declaring both up front makes that work without the user having to know the
# knobs exist. The other providers name models the CLI knows, so they are deliberately left unset there.
GATEWAY_DEFAULT_MAX_CONTEXT_TOKENS=262144
GATEWAY_DEFAULT_AUTO_COMPACT_WINDOW=200000

# Every key this arm may write. run.sh --reset clears them all so switching providers is clean.
# shellcheck disable=SC2034  # consumed by run.sh --reset
GATEWAY_KEYS=(ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN
              CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS CLAUDE_CODE_MAX_CONTEXT_TOKENS CLAUDE_CODE_AUTO_COMPACT_WINDOW)

# Prompt for a value that may legitimately be empty. resolve() cannot do this: it re-prompts until it
# gets something, which is right for a password and wrong for "token, if your gateway needs one".
# flag > .env > prompt; a blank answer stays blank; typing `none` also means blank (so a re-run can
# deliberately clear a saved token — an empty answer alone would just fall through to the saved one).
gateway_resolve_optional() { # flagval envkey prompt
  local cur="$1" envkey="$2" prompt="$3"
  [ -z "$cur" ] && cur="$(getenv "$envkey")"
  if [ -z "$cur" ] && [ "$NONINTERACTIVE" != 1 ]; then read -rs -p "$prompt: " cur; echo >&2; fi
  [ "$cur" = none ] && cur=""
  printf '%s' "$cur"
}

# Write <envkey>, preferring a flag, then whatever is already in .env (a hand-edit or an earlier run
# survives), then the default.
gateway_set_default() { # envkey flagval default
  local v="$2"
  [ -z "$v" ] && v="$(getenv "$1")"
  [ -z "$v" ] && v="$3"
  setenv "$1" "$v"
}

provider_gateway_configure() {
  local url token model
  if [ "$NONINTERACTIVE" != 1 ] && [ -z "$F_GATEWAY_URL" ] && [ -z "$(getenv ANTHROPIC_BASE_URL)" ]; then
    cat >&2 <<'TXT'

  An LLM gateway is a service that sits in front of one or more model providers and speaks the
  Anthropic API — OpenRouter, Bifrost, LiteLLM and Snowflake Cortex all work. The gateway holds
  the real provider credentials; the dev kit only needs to know where it is and how to log in.

  You'll be asked for three things:
    1. the gateway's base URL  — the address your gateway documents for Anthropic-style requests,
                                 e.g. https://openrouter.ai/api. Do not include /v1/messages.
                                 For a gateway running on THIS machine (a local Bifrost, say) use
                                 http://host.docker.internal:8080, not localhost — the agent runs
                                 in a container, where localhost is the container itself.
    2. an access token         — the API key or bearer token the gateway gave you. Just press Enter
                                 if your gateway doesn't require one (a local Bifrost, for instance).
    3. a model name            — exactly as your gateway lists it. OpenRouter uses names like
                                 anthropic/claude-sonnet-5; a pass-through gateway usually takes
                                 the plain Anthropic id, e.g. claude-sonnet-5.

TXT
  fi

  url="$F_GATEWAY_URL"; [ -z "$url" ] && url="$(getenv ANTHROPIC_BASE_URL)"
  if [ -z "$url" ]; then
    [ "$NONINTERACTIVE" = 1 ] && { echo "Missing gateway URL — pass --gateway-url <url> (non-interactive)." >&2; return 1; }
    read -r -p 'Gateway base URL (e.g. https://openrouter.ai/api): ' url
  fi
  url="${url%/}"
  case "$url" in
    http://*|https://*) ;;
    *) echo "The gateway URL must start with http:// or https:// (got '$url')." >&2; return 1 ;;
  esac
  case "$url" in
    http://localhost*|https://localhost*|http://127.0.0.1*|https://127.0.0.1*)
      echo "    note: '$url' points at localhost — inside the agent container that is the container itself, not this machine. Use http://host.docker.internal:<port> if the gateway runs here." >&2 ;;
  esac

  token="$(gateway_resolve_optional "$F_GATEWAY_TOKEN" ANTHROPIC_AUTH_TOKEN \
             'Gateway access token / API key (press Enter if your gateway needs none)')"

  model="$F_GATEWAY_MODEL"; [ -z "$model" ] && model="$(getenv CLAUDE_MODEL)"
  if [ -z "$model" ] && [ "$NONINTERACTIVE" != 1 ]; then
    read -r -p "Model name as your gateway lists it [$GATEWAY_DEFAULT_MODEL]: " model
  fi
  [ -n "$model" ] || model="$GATEWAY_DEFAULT_MODEL"

  setenv ANTHROPIC_BASE_URL "$url"
  setenv ANTHROPIC_AUTH_TOKEN "$token"
  setenv CLAUDE_MODEL "$model"
  setenv CLAUDE_EXTRA_MODELS ""  # gateways name models their own way — register only the one you gave us
  setenv ANTHROPIC_API_KEY ""   # load-bearing — see header

  # Per-gateway tuning. Flag > value already in .env > default. The two window sizes always end up set
  # (see the defaults above); the betas knob is left alone unless asked for, since most gateways strip
  # those headers themselves and only Snowflake Cortex rejects them outright.
  [ -z "$F_GATEWAY_DISABLE_BETAS" ] || setenv CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS "$F_GATEWAY_DISABLE_BETAS"
  gateway_set_default CLAUDE_CODE_MAX_CONTEXT_TOKENS  "$F_GATEWAY_MAX_CONTEXT"    "$GATEWAY_DEFAULT_MAX_CONTEXT_TOKENS"
  gateway_set_default CLAUDE_CODE_AUTO_COMPACT_WINDOW "$F_GATEWAY_COMPACT_WINDOW" "$GATEWAY_DEFAULT_AUTO_COMPACT_WINDOW"

  # Same reason as the anthropic arm: the agent's title LLM is Bedrock-only and needs a well-formed
  # region to not crash-loop; with no AWS creds the title call simply no-ops.
  [ -n "$(getenv AWS_REGION)" ] || setenv AWS_REGION "us-east-1"

  echo "    using LLM gateway at $url (model: $model${token:+, with access token})."
  echo "    context window $(getenv CLAUDE_CODE_MAX_CONTEXT_TOKENS) tokens, compacting at $(getenv CLAUDE_CODE_AUTO_COMPACT_WINDOW) — override with --gateway-max-context-tokens / --gateway-compact-window."
  [ -z "$(getenv AWS_ACCESS_KEY_ID)" ] || echo "    note: AWS keys are still set in .env — harmless (the gateway path never uses them), but ./run.sh --reset clears them if you'd rather they were gone."
}
