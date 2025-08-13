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
# 步骤1：更新软件源配置
RUN sed -i -e 's/deb.debian.org/archive.debian.org/g' \
    -e 's|security.debian.org|archive.debian.org|g' \
    -e '/-updates/d' /etc/apt/sources.list

# 步骤2：安装基础工具
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        ca-certificates curl gnupg2 wget git && \
    rm -rf /var/lib/apt/lists/*

# 步骤3：添加第三方软件源
RUN \
    # --- Nginx ---
    curl -fsSL https://nginx.org/keys/nginx_signing.key -o /tmp/nginx.key && \
    gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg < /tmp/nginx.key && \
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/debian/ buster nginx" > /etc/apt/sources.list.d/nginx.list && \
    \
    # --- PostgreSQL ---
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /tmp/postgres.key && \
    gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg < /tmp/postgres.key && \
    echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt-archive.postgresql.org/pub/repos/apt/ buster-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    \
    # --- Yarn ---
    curl -fsSL https://dl.yarnpkg.com/debian/pubkey.gpg -o /tmp/yarn.key && \
    gpg --dearmor -o /usr/share/keyrings/yarn-archive-keyring.gpg < /tmp/yarn.key && \
    echo "deb [signed-by=/usr/share/keyrings/yarn-archive-keyring.gpg] https://dl.yarnpkg.com/debian/ stable main" > /etc/apt/sources.list.d/yarn.list

# 步骤4：安装主要软件包
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        software-properties-common sudo supervisor logrotate locales \
        apt-transport-https openssh-server gettext-base \
        shared-mime-info gawk bison libtool sqlite3 libgpgme11 libmariadb-dev \
        default-mysql-client postgresql-client redis-tools \
        python2.7 && \
    rm -rf /var/lib/apt/lists/*

# 步骤5：安装 Nginx 和 Yarn
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        nginx yarn && \
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
