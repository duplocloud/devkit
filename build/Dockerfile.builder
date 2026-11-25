# Toolchain image for building dev-kit extensions: .NET SDK 10 + the .NET 8 runtime + Node 22 plus the shell tools
# scripts/build-extension.sh needs. The SDK builds net8.0 as well as net10.0, and the script picks the target
# framework from the host SDK version, so one toolchain serves hosts on either runtime. The .NET 8 shared runtime
# is there for the ArmDot step, which runs on the built assembly and needs the runtime that assembly targets: without
# it a release that lists a 1.0.x or 1.1.x SDK version builds its net8.0 bundle and then fails to obfuscate it with
# "Failed to find a .NET Core runtime v8.0". It is copied from Microsoft's 8.0 runtime image, pinned by digest, the way
# Node is copied below; the SDK image's own 10.0 runtime stays beside it.
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
# mcr.microsoft.com/dotnet/aspnet:8.0-noble, 8.0.34 runtimes (docker buildx imagetools inspect), multi-arch.
FROM mcr.microsoft.com/dotnet/aspnet:8.0-noble@sha256:fb50a3d0efad014b4fa8ee85fa498818172e38216cc73742821319f9db827bb2 AS net8

FROM mcr.microsoft.com/dotnet/sdk:10.0-noble
COPY --from=net8 /usr/share/dotnet/shared/Microsoft.NETCore.App /usr/share/dotnet/shared/Microsoft.NETCore.App
COPY --from=net8 /usr/share/dotnet/shared/Microsoft.AspNetCore.App /usr/share/dotnet/shared/Microsoft.AspNetCore.App
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
 && chmod 777 /cache /cache/nuget /cache/npm \
 # The .NET 10 CLI takes a named mutex on its first run and throws "cannot open the device or file
 # 'NuGet-Migrations'" when neither of its home directories exists yet; the .NET 8 CLI created them on
 # demand. Both are created here, world-writable like /tmp, so the caller's arbitrary uid can fill them.
 && mkdir -p /tmp/build-home /tmp/dotnet-home \
 && chmod 1777 /tmp/build-home /tmp/dotnet-home

# Quieten the first-run banner and telemetry, and keep the package caches on the mounted volumes.
#
# HOME and DOTNET_CLI_HOME deliberately are not volumes. They hold regenerable CLI state — first-use
# sentinels, a generated NuGet.Config, template metadata — and persisting that state in a shared volume is
# what broke cross-uid builds: dotnet creates .nuget/NuGet/ as 0755 and NuGet.Config as 0600 owned by the
# first uid to run, so a later run as a different uid died with "Access to the path '.../NuGet.Config' is
# denied". Under /tmp, which is never a volume, each container gets its own throwaway copy.
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
