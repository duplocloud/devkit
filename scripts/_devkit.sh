# shellcheck shell=bash
# Sourced by scripts/* — single source of truth for the dev-kit origin.
#
# The dev-kit URL is FIXED here and must never be taken from user input, `.devkit-version`, or `git remote`.
# upgrade_dev_kit.sh always clones the framework from this URL; change_git_owner.sh / init-project.sh record
# it verbatim into .devkit-version. This prevents an adopted repo (whose `origin` is the user's own remote)
# from redirecting a framework upgrade at a non-official source.
# shellcheck disable=SC2034  # used by the scripts that source this file
DEVKIT_URL="https://github.com/duplocloud/devkit"
