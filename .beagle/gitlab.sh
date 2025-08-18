#!/bin/bash
set -e

GITLAB_CLONE_URL=https://gitlab.com/gitlab-org/gitlab-ce.git
GITLAB_SHELL_URL=https://gitlab.com/gitlab-org/gitlab-shell/-/archive/v${GITLAB_SHELL_VERSION}/gitlab-shell-v${GITLAB_SHELL_VERSION}.tar.bz2
GITLAB_WORKHORSE_URL=https://gitlab.com/gitlab-org/gitlab-workhorse.git
GITLAB_PAGES_URL=https://gitlab.com/gitlab-org/gitlab-pages.git
GITLAB_GITALY_URL=https://gitlab.com/gitlab-org/gitaly.git

GITLAB_WORKHORSE_BUILD_DIR=/tmp/gitlab-workhorse
GITLAB_PAGES_BUILD_DIR=/tmp/gitlab-pages
GITLAB_GITALY_BUILD_DIR=/tmp/gitaly

GEM_CACHE_DIR="${GITLAB_BUILD_DIR}/cache"

GOROOT=/tmp/go
PATH=${GOROOT}/bin:$PATH

# 1. 检测系统架构并设置Go语言对应的架构名称
MACHINE_ARCH=$(uname -m)
case "${MACHINE_ARCH}" in
    x86_64)
        GO_ARCH="amd64"
        ;;
    aarch64)
        GO_ARCH="arm64"
        ;;
    *)
        echo "不支持的架构: ${MACHINE_ARCH}"
        exit 1
        ;;
esac

export GOROOT PATH

BUILD_DEPENDENCIES="gcc g++ make patch pkg-config cmake build-essential \
  python2.7-dev python-docutils \
  libc6-dev \
  libmariadb-dev-compat libmariadb-dev libpq-dev zlib1g-dev libyaml-dev libssl-dev \
  libgdbm-dev libreadline-dev libncurses5-dev libffi-dev \
  libxml2-dev libxslt-dev libcurl4-openssl-dev libicu-dev \
  gettext libkrb5-dev libgmp-dev libre2-dev \
  libgpg-error-dev libassuan-dev libgpgme-dev \
  libgrpc-dev libgrpc++-dev protobuf-compiler-grpc libssh2-1-dev libxslt1-dev \
  autoconf automake libsqlite3-dev"

# 运行时需要的库（不能删除）
RUNTIME_DEPENDENCIES="libre2-5 libgrpc6 libprotobuf17 libmariadb3 libpq5 \
  libgpgme11 libassuan0 libgpg-error0 \
  zlib1g libyaml-0-2 libssl1.1 libgdbm6 libreadline7 libncurses6 libffi6 \
  libxml2 libxslt1.1 libcurl4 libicu63 libkrb5-3 libgmp10 libssh2-1 libsqlite3-0"

## Execute a command as GITLAB_USER
exec_as_git() {
  if [[ $(whoami) == "${GITLAB_USER}" ]]; then
    "$@"
  else
    sudo -HEu ${GITLAB_USER} "$@"
  fi
}

# remove the host keys generated during openssh-server installation
rm -rf /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub

# add ${GITLAB_USER} user
if ! id "${GITLAB_USER}" >/dev/null 2>&1; then
  echo "INFO: User '${GITLAB_USER}' not found, creating it..."
  adduser --disabled-login --gecos 'GitLab' --home ${GITLAB_HOME} ${GITLAB_USER}
  passwd -d ${GITLAB_USER}
else
  echo "INFO: User '${GITLAB_USER}' already exists, skipping creation."
fi

cat >> ${GITLAB_HOME}/.profile <<EOF
PATH=/usr/local/sbin:/usr/local/bin:\$PATH

# Golang
GOROOT=/tmp/go
PATH=\${GOROOT}/bin:\$PATH
EOF

# configure git for ${GITLAB_USER}
exec_as_git git config --global core.autocrlf input
exec_as_git git config --global gc.auto 0
exec_as_git git config --global repack.writeBitmaps true
exec_as_git git config --global receive.advertisePushOptions true

# shallow clone gitlab-ce
if ! [ -d ${GITLAB_INSTALL_DIR} ]; then
  echo "Cloning gitlab-ce v${GITLAB_VERSION}..."
  exec_as_git git clone -q --depth 1 --branch v${GITLAB_VERSION} ${GITLAB_CLONE_URL} ${GITLAB_INSTALL_DIR}
fi

GITLAB_SHELL_VERSION=${GITLAB_SHELL_VERSION:-$(cat ${GITLAB_INSTALL_DIR}/GITLAB_SHELL_VERSION)}
GITLAB_WORKHORSE_VERSION=${GITLAB_WORKHORSE_VERSION:-$(cat ${GITLAB_INSTALL_DIR}/GITLAB_WORKHORSE_VERSION)}
GITLAB_PAGES_VERSION=${GITLAB_PAGES_VERSION:-$(cat ${GITLAB_INSTALL_DIR}/GITLAB_PAGES_VERSION)}

# remove HSTS config from the default headers, we configure it in nginx
exec_as_git sed -i "/headers\['Strict-Transport-Security'\]/d" ${GITLAB_INSTALL_DIR}/app/controllers/application_controller.rb

# revert `rake gitlab:setup` changes from gitlabhq/gitlabhq@a54af831bae023770bf9b2633cc45ec0d5f5a66a
exec_as_git sed -i 's/db:reset/db:setup/' ${GITLAB_INSTALL_DIR}/lib/tasks/gitlab/setup.rake

cd ${GITLAB_INSTALL_DIR}

# --- 还原 Gemfile 和 Gemfile.lock 到原始状态 ---
echo "INFO: Restoring original Gemfile and Gemfile.lock from git..."
exec_as_git git config --global --add safe.directory ${GITLAB_INSTALL_DIR}
exec_as_git git checkout HEAD -- Gemfile Gemfile.lock
# --- 还原结束 ---

# install gems, use local cache if available
chown -R ${GITLAB_USER}: ${GITLAB_INSTALL_DIR}/vendor
chown -R ${GITLAB_USER}: /usr/local/bundle/config

# Bundle install moved to later section with proper configuration

# make sure everything in ${GITLAB_HOME} is owned by ${GITLAB_USER} user
chown -R ${GITLAB_USER}: ${GITLAB_HOME}

# --- 精确修复关键 gems：grpc、rugged、gpgme ---
echo "INFO: Setting up bundle configuration for ARM64 compatibility..."

# 1. 修复 grpc gem - 使用系统库避免编译问题
echo "INFO: Configuring grpc gem for ARM64..."
exec_as_git bundle config build.grpc --with-system-libraries

# 3. 修复 gpgme gem - 使用系统库
echo "INFO: Configuring gpgme gem for system libraries..."
exec_as_git bundle config build.gpgme --use-system-libraries

# 4. 强制使用Ruby平台版本，避免预编译二进制版本的兼容性问题
exec_as_git bundle config --local force_ruby_platform true

exec_as_git bundle config mirror.https://rubygems.org https://mirrors.tuna.tsinghua.edu.cn/rubygems

# 预先安装关键的问题 gems，使用 Gemfile.lock 中的确切版本
echo "INFO: Pre-installing problematic gems with exact versions from Gemfile.lock..."

# 修复 mimemagic 问题 - 使用一个兼容的版本
if grep -q "gem 'mimemagic', '~> 0.3.2'" Gemfile; then
  echo "INFO: Replacing mimemagic 0.3.2 with compatible version..."
  # 使用 mimemagic 0.3.10，这个版本比较稳定且不需要额外依赖
  sed -i "s/gem 'mimemagic'.*/gem 'mimemagic', '~> 0.3.10'/" Gemfile
  # 更新 Gemfile.lock
  exec_as_git bundle config --local path vendor/bundle
  exec_as_git bundle config --delete deployment
  exec_as_git bundle config --delete frozen
  exec_as_git bash -l -c '
    export CFLAGS="${CFLAGS} -Wno-error=stringop-overflow -Wno-error=sizeof-pointer-memaccess -Wno-error" && \
    export CXXFLAGS="${CXXFLAGS} -Wno-error=stringop-overflow -Wno-error=sizeof-pointer-memaccess -Wno-error" && \
    export GRPC_RUBY_COMPILE_PLATFORM_ONLY=true && \
    bundle update mimemagic --conservative
  '
fi

# 尝试 bundle install，使用 --full-index 来解决依赖问题
exec_as_git bundle install -j"$(nproc)" --local --without development test aws

echo "INFO: Bundle install completed successfully"

# make sure everything in ${GITLAB_HOME} is owned by ${GITLAB_USER} user
chown -R ${GITLAB_USER}: ${GITLAB_HOME}

# gitlab.yml and database.yml are required for `assets:precompile`
exec_as_git cp ${GITLAB_INSTALL_DIR}/config/resque.yml.example ${GITLAB_INSTALL_DIR}/config/resque.yml
exec_as_git cp ${GITLAB_INSTALL_DIR}/config/gitlab.yml.example ${GITLAB_INSTALL_DIR}/config/gitlab.yml
exec_as_git cp ${GITLAB_INSTALL_DIR}/config/database.yml.mysql ${GITLAB_INSTALL_DIR}/config/database.yml

# Installs nodejs packages required to compile webpack
exec_as_git yarn install --production --pure-lockfile
exec_as_git yarn add ajv@^4.0.0

echo "Compiling assets. Please be patient, this could take a while..."
exec_as_git bundle exec rake gitlab:assets:compile USE_DB=false SKIP_STORAGE_VALIDATION=true NODE_OPTIONS="--max-old-space-size=4096"
rm -rf ${GITLAB_INSTALL_DIR}/ruby/vendor/bundle/ruby/**/cache

echo "INFO: Assets compilation completed successfully"
# --- 修复结束 ---
