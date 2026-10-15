FROM ruby:4.0.5-bookworm

ARG BUNDLER_VERSION=4.0.13
ARG USER_GID=1000
ARG USER_UID=1000
ARG USERNAME=vscode

RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y build-essential chromium curl git libyaml-dev pkg-config sqlite3 sudo \
    && gem install bundler --version ${BUNDLER_VERSION} --no-document \
    && groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} --create-home --shell /bin/bash ${USERNAME} \
    && echo "${USERNAME} ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME} \
    && rm -rf /var/lib/apt/lists/*

ENV BUNDLE_PATH=/usr/local/bundle

RUN mkdir -p ${BUNDLE_PATH} && chown -R ${USERNAME}:${USERNAME} ${BUNDLE_PATH}

USER ${USERNAME}
