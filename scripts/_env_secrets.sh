# Sourced by run.sh and scripts/switch-llm.sh (both define getenv/setenv). Not executable on its own.
#
# A provider secret exported in the calling shell — `op run`, a keychain lookup, a CI secret — can be used
# for this run without ever being written to .env. docker-compose.yml interpolates these variables from
# the environment BEFORE .env, so the agent receives the shell value.
#
# That same compose rule is also the hazard: any exported provider key reaches the agent, whichever
# provider was chosen, and wins its precedence chain (an exported ANTHROPIC_API_KEY beats Bedrock, and is
# sent to a gateway's URL). So the contract is explicit: a key is taken from the environment only when
# the chosen provider's arm calls env_take for it; env_isolate then unsets every other provider key in
# this process, so compose reads .env for those. This process only — the user's shell is untouched.
#
# Precedence for the chosen provider: flag > .env > environment > prompt. A value already in .env still
# wins, so existing setups behave as before; the environment only fills what .env leaves empty, which
# used to mean a prompt (or a hard exit under --non-interactive).

# Every credential docker-compose.yml passes to the agent via ${VAR:-}, plus AWS_REGION: not a secret, but
# an exported region would silently beat the one written to .env and make the Bedrock model unavailable.
PROVIDER_ENV_KEYS=(ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
  AZURE_BASE_URL AZURE_API_KEY AZURE_CLIENT_ID AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  AWS_REGION)
ENV_TAKEN=()

env_supplied() { # flagval envkey -> 0 when envkey should come from the environment, not .env
  [ -z "$1" ] && [ -z "$(getenv "$2")" ] && [ -n "${!2:-}" ]
}

env_take() { # envkey... -> keep these exported values for the agent (not written to .env)
  ENV_TAKEN+=("$@")
}

env_taken() { # envkey -> 0 when env_take recorded it
  local k
  for k in ${ENV_TAKEN[@]+"${ENV_TAKEN[@]}"}; do [ "$k" = "$1" ] && return 0; done
  return 1
}

# Bedrock with keys from the environment: .env can never hold the matching session token, so blank it;
# a --aws-session-token flag is exported rather than written, keeping the "nothing stored" contract.
env_take_session_token() { # flagval
  setenv AWS_SESSION_TOKEN ""
  [ -n "$1" ] && export AWS_SESSION_TOKEN="$1"
  [ -n "${AWS_SESSION_TOKEN:-}" ] && env_take AWS_SESSION_TOKEN
  return 0
}

# Call right before `compose up`. Unsets every provider key not taken via env_take, so compose falls
# back to .env for it; names a non-empty one so a shadowed export is not a silent surprise.
env_isolate() {
  local k ignored=""
  for k in "${PROVIDER_ENV_KEYS[@]}"; do
    env_taken "$k" && continue
    [ -n "${!k+x}" ] || continue
    [ -n "${!k}" ] && ignored="$ignored $k"
    unset "$k"
  done
  [ -z "$ignored" ] || echo "    note: ignoring$ignored exported in your shell — this run uses .env for those."
  return 0
}
