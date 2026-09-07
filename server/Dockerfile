# syntax=docker/dockerfile:1

# In-House Code Push — dashboard + code-push API (Dart Frog).
# Mirrors tooling/dashboard-serve.sh --prod, AOT-compiled and served from the
# official minimal `scratch` runtime (see dart:stable's /runtime/).
#
# The server source is CLONED from the git repo at a pinned commit (CODEPUSH_REF)
# rather than COPY'd, so the image is reproducible from any build context. Only
# server/ is checked out (sparse) to keep the image small.
#
# The repo is PUBLIC, so the clone needs no credentials.
#
# Runtime configuration — set these in Coolify (Environment Variables):
#   ADMIN_TOKEN              required — Bearer token guarding /admin/*
#   PUBLIC_BASE_URL          device-reachable URL advertised in patch download
#                            URLs (e.g. https://codepush.yourdomain.com)
#   CODEPUSH_APP_ID          package id devices send in the check call
#   CODEPUSH_RELEASE_VERSION release this server pushes patches for
#   PATCH_STORAGE_DIR        patch store (defaults to /data/patches)
#   PATCH_PRIVATE_KEY_PATH   optional RSA PEM key for patch signing (empty = off)
#   PORT                     default 8080
#
# Leave PUSH_BRANCH_SCRIPT and WORKTREE_DIR unset: the dashboard's "build from
# branch" picker needs a Flutter checkout + tooling that doesn't exist in this
# container and is automatically hidden when those vars are empty.
#
# Mount a persistent volume at /data/patches so uploaded patch artifacts and the
# registry.json index survive restarts.

ARG DART_VERSION=3.12
ARG CODEPUSH_REPO=https://github.com/millbox5/inhouse-codepush.git
ARG CODEPUSH_BRANCH=main
ARG CODEPUSH_REF=20893f6

FROM dart:${DART_VERSION} AS build

# ARG declared before FROM are not visible to RUN; redeclare to reuse the values.
ARG CODEPUSH_REPO
ARG CODEPUSH_BRANCH
ARG CODEPUSH_REF

# git is needed for the clone below.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Pin the same dart_frog_cli used for local dev (matching pubspec sdk ^3.5.0).
RUN dart pub global activate dart_frog_cli --version 1.2.14
ENV PATH="$PATH:/root/.pub-cache/bin"

# Sparse-checkout only server/ at the pinned commit into /src. GitHub won't
# serve a bare SHA, so fetch the branch's full history (blob:none keeps it slim
# and sparse checkout fetches blobs only for server/), then check out the pinned
# ref — which may be any ancestor, not just the branch tip.
RUN git init -q /src \
    && mkdir -p /src/.git/info \
    && printf 'server/\n' > /src/.git/info/sparse-checkout \
    && git -C /src config core.sparsecheckout true \
    && git -C /src remote add origin "${CODEPUSH_REPO}" \
    && GIT_TERMINAL_PROMPT=0 git -C /src fetch --filter=blob:none --no-tags origin "${CODEPUSH_BRANCH}" \
    && git -C /src checkout -q "${CODEPUSH_REF}" \
    && test -f /src/server/pubspec.yaml

WORKDIR /src/server

# Resolve dependencies and generate the deployable project.
RUN dart pub get \
    && dart_frog build

# AOT-compile the generated entrypoint into a self-contained binary.
WORKDIR /src/server/build
RUN mkdir -p /out \
    && dart pub get --offline \
    && dart compile exe bin/server.dart -o /out/server

# Minimal serving image: /runtime/ carries the Dart runtime + shared libraries
# the AOT binary is linked against.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /out/server /usr/local/bin/server

WORKDIR /app
VOLUME /data/patches

ENV PORT=8080 \
    PATCH_STORAGE_DIR=/data/patches \
    ADMIN_TOKEN=change-me \
    PUBLIC_BASE_URL=http://localhost:8080 \
    CODEPUSH_APP_ID=com.example.app \
    CODEPUSH_RELEASE_VERSION=1.0.0

EXPOSE 8080
CMD ["/usr/local/bin/server"]