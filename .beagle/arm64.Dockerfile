ARG BASE=ruby:2.5.8

FROM ${BASE}

ARG BUILD_DATE
ARG VCS_REF
ARG VERSION=11.11.3

ENV GITLAB_VERSION=${VERSION} \
    RUBY_VERSION=2.5.8 \
    GOLANG_VERSION=1.12.6 \
    GITLAB_SHELL_VERSION=9.1.0 \
    GITLAB_WORKHORSE_VERSION=8.7.0 \
    GITLAB_PAGES_VERSION=1.5.0 \
    GITALY_SERVER_VERSION=1.42.7 \
    GITLAB_USER="git" \
    GITLAB_HOME="/home/git" \
    GITLAB_LOG_DIR="/var/log/gitlab" \
    GITLAB_CACHE_DIR="/etc/docker-gitlab" \
    RAILS_ENV=production \
    NODE_ENV=production

ENV GITLAB_INSTALL_DIR="${GITLAB_HOME}/gitlab" \
    GITLAB_SHELL_INSTALL_DIR="${GITLAB_HOME}/gitlab-shell" \
    GITLAB_GITALY_INSTALL_DIR="${GITLAB_HOME}/gitaly" \
    GITLAB_DATA_DIR="${GITLAB_HOME}/data" \
    GITLAB_BUILD_DIR="${GITLAB_CACHE_DIR}/build" \
    GITLAB_RUNTIME_DIR="${GITLAB_CACHE_DIR}/runtime"

# --- 构建依赖安装 ---
RUN sed -i -e 's/deb.debian.org/archive.debian.org/g' \
       -e 's|security.debian.org|archive.debian.org|g' \
       -e '/-updates/d' /etc/apt/sources.list && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive \
    apt-get install --no-install-recommends -y \
        wget curl ca-certificates apt-transport-https software-properties-common \
        sudo supervisor logrotate locales \
        openssh-server default-mysql-client postgresql-client redis-tools \
        libgpgme11 gettext-base shared-mime-info gawk bison libtool sqlite3 gnupg2 \
        git python2.7 && \
    # --- Nginx (官方源) ---
    wget --quiet -O - https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/debian/ buster nginx" > /etc/apt/sources.list.d/nginx.list && \
    # --- PostgreSQL ---
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - && \
    echo 'deb http://apt-archive.postgresql.org/pub/repos/apt/ buster-pgdg main' > /etc/apt/sources.list.d/pgdg.list && \
    # --- 添加 Yarn 源 ---
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \
    echo 'deb https://dl.yarnpkg.com/debian/ stable main' > /etc/apt/sources.list.d/yarn.list && \
    # --- 安装构建时依赖 ---
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        nginx \
        yarn && \
    # --- 清理 ---
    rm -rf /var/lib/apt/lists/* /tmp/*

COPY assets/build/ ${GITLAB_BUILD_DIR}/
COPY .beagle/install_arm64_debug.sh ${GITLAB_BUILD_DIR}/install.sh
RUN bash ${GITLAB_BUILD_DIR}/install.sh

COPY assets/runtime/ ${GITLAB_RUNTIME_DIR}/
COPY entrypoint.sh /sbin/entrypoint.sh
RUN chmod 755 /sbin/entrypoint.sh

LABEL \
    maintainer="sameer@damagehead.com" \
    org.label-schema.schema-version="1.0" \
    org.label-schema.build-date=${BUILD_DATE} \
    org.label-schema.name=gitlab \
    org.label-schema.vendor=damagehead \
    org.label-schema.url="https://github.com/sameersbn/docker-gitlab" \
    org.label-schema.vcs-url="https://github.com/sameersbn/docker-gitlab.git" \
    org.label-schema.vcs-ref=${VCS_REF} \
    com.damagehead.gitlab.license=MIT

EXPOSE 22/tcp 80/tcp 443/tcp

VOLUME ["${GITLAB_DATA_DIR}", "${GITLAB_LOG_DIR}"]
WORKDIR ${GITLAB_INSTALL_DIR}
ENTRYPOINT ["/sbin/entrypoint.sh"]
CMD ["app:start"]
