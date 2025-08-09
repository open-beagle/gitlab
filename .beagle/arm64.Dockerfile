ARG BASE=ubuntu:20.04

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
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive \
    apt-get install --no-install-recommends -y \
        # 基础工具
        wget curl gnupg2 ca-certificates apt-transport-https software-properties-common \
        # 核心依赖
        sudo supervisor logrotate locales curl \
        openssh-server mysql-client postgresql-client redis-tools \
        # rake运行时依赖
        libgpgme11 libmysqlclient21 \
        # 编译工具
        git python2.7 && \
    #
    # --- 添加软件源 (使用现代化的 gpg 方式) ---
    #
    # Git (来自 PPA)
    add-apt-repository -y ppa:git-core/ppa && \
    # Nginx (来自 PPA)
    add-apt-repository -y ppa:nginx/stable && \
    # PostgreSQL
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - && \
    echo 'deb http://apt-archive.postgresql.org/pub/repos/apt/ focal-pgdg main' > /etc/apt/sources.list.d/pgdg.list && \
    wget --quiet -O - https://dl.yarnpkg.com/debian/pubkey.gpg  | apt-key add -  && \
    echo 'deb https://dl.yarnpkg.com/debian/ stable main' > /etc/apt/sources.list.d/yarn.list && \
    #
    # --- 安装构建时依赖 ---
    #
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        # Git
        git-core gnupg2 \
        # Nginx
        nginx \
        # Yarn
        yarn gettext-base \
        # 其他编译 GitLab 所需的开发库
        shared-mime-info \
        gawk bison libtool sqlite3 && \
    # --- 清理 ---
    #
    rm -rf /var/lib/apt/lists/* /tmp/*

COPY assets/build/ ${GITLAB_BUILD_DIR}/
COPY .beagle/install_arm64.sh ${GITLAB_BUILD_DIR}/install.sh
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
