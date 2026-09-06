# syntax=docker/dockerfile:1

# In-House Code Push — dashboard + code-push API (Dart Frog).
# Mirrors tooling/dashboard-serve.sh --prod, AOT-compiled and served from the
# official minimal `scratch` runtime (see dart:stable's /runtime/).
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

FROM dart:${DART_VERSION} AS build

WORKDIR /app

# Pin the same dart_frog_cli used for local dev (matching pubspec sdk ^3.5.0).
RUN dart pub global activate dart_frog_cli --version 1.2.14
ENV PATH="$PATH:/root/.pub-cache/bin"

# Resolve dependencies first so this layer is cached separately from the source.
COPY pubspec.yaml ./
RUN dart pub get

# Copy the server source (routes/, lib/) and generate the deployable project.
COPY . .
RUN dart_frog build

# AOT-compile the generated entrypoint into a self-contained binary.
WORKDIR /app/build
RUN dart pub get --offline \
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