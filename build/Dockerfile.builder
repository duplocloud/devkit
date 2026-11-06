# Toolchain image for building dev-kit extensions: .NET SDK 10 (the backend targets net10.0) + Node 22
# plus the shell tools scripts/build-extension.sh needs.
#
# Node 22 tracks the frontend, it is not a preference. The samples are Angular 22, whose declared engines
# are "^22.22.3 || ^24.15.0 || >=26.0.0" — so the 22.x line satisfies Angular only from 22.22.3 up. The
# floating node:22-* tag is well past that today, but it IS floating: if you ever pin a specific 22.x
# patch it must be >= 22.22.3, or the Angular build breaks. Do not pick an odd major (23, 25) — Angular
# 22's range excludes them and they never reach LTS.
#
# NOTE: portal/package.json declares "node": ">= 22.12.0". That is Angular 21's floor and is too low for
# the Angular 22 it depends on — do not copy that number here.
#
# Node is copied from the official node image rather than installed from a third-party apt repo, which
# keeps the image multi-arch (amd64 for CI, arm64 for Apple Silicon laptops) without trusting an extra
# package source. Both tags float, so this is not a reproducible build; pinning is a separate concern.
FROM node:22-bookworm-slim AS node

FROM mcr.microsoft.com/dotnet/sdk:10.0-noble
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && apt-get update \
 # jq/zip/unzip/file/curl are used directly by build-extension.sh. `file` appears only in the error path
 # that reports what a bad SDK download actually was (an HTML login page, a JSON error), so omitting it
 # silently degrades that diagnostic to "got .". git is NOT used by the build scripts; it is here because
 # a user extension may declare a git:/git+https npm dependency. curl, ca-certificates and git already
 # ship in the SDK base image and are listed anyway so a base-image change cannot silently remove them.
 && apt-get install -y --no-install-recommends jq zip unzip file curl ca-certificates git \
 && rm -rf /var/lib/apt/lists/* \
 # A fresh named volume inherits the mode of the image directory it is mounted over, so the two cache
 # mount points must be world-writable for the caller's arbitrary uid (see the compose `user:`) to write
 # them on first mount — no init-perms-style chown pass needed. Both subdirectories are named explicitly
 # because `chmod 777 /cache` alone would leave them 755, and therefore unwritable.
 #
 # Directories created *inside* the caches at runtime inherit the caller's umask and are owned by that
 # uid, so one uid's cache is not writable by another. That is why each uid gets its OWN cache volumes
 # (compose interpolates the uid into the volume name) rather than sharing a pair. The alternative —
 # relaxing the umask so uids can share — cannot be contained to /cache: umask is process-global, so it
 # would also make the build's output in the bind-mounted /work world-writable, including node_modules/
 # and the extension.zip we hand to the user.
 && mkdir -p /cache/nuget /cache/npm \
 && chmod 777 /cache /cache/nuget /cache/npm

# Quieten the first-run banner and telemetry, and keep the package caches on the mounted volumes.
#
# HOME and DOTNET_CLI_HOME deliberately are neither volumes nor pre-created (the tools create them on
# demand). They hold regenerable CLI state — first-use sentinels, a generated NuGet.Config, template
# metadata — and persisting that state in a shared volume is what broke cross-uid builds: dotnet creates
# .nuget/NuGet/ as 0755 and NuGet.Config as 0600 owned by the first uid to run, so a later run as a
# different uid died with "Access to the path '.../NuGet.Config' is denied". /tmp is 1777 and never a
# volume, so each container gets its own throwaway copy.
ENV DOTNET_NOLOGO=1 \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_CLI_HOME=/tmp/dotnet-home \
    NUGET_PACKAGES=/cache/nuget \
    npm_config_cache=/cache/npm \
    HOME=/tmp/build-home

# The extension source is bind-mounted here. NOTE: a *named volume* mounted at any path this image does
# not pre-create world-writable comes up 755 root:root and the caller's uid cannot write it — so the
# tempting /work/**/node_modules volume (to dodge slow virtiofs on macOS) needs a matching mkdir+chmod
# above before it will work.
WORKDIR /work

# .NET 10 first-run initialization needs these homes to exist before taking its NuGet mutex.
# Create them as the invoking uid, rather than baking root-owned CLI state into the image.
ENTRYPOINT ["bash", "-c", "mkdir -p \"$HOME\" \"$DOTNET_CLI_HOME\" && exec \"$@\"", "--"]
