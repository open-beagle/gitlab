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

# install build dependencies for gem installation
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y ${BUILD_DEPENDENCIES} ${RUNTIME_DEPENDENCIES}

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

# download golang
if ! [ -d /tmp/go ]; then
  echo "Downloading Go ${GOLANG_VERSION}..."
  wget -cnv https://storage.googleapis.com/golang/go${GOLANG_VERSION}.linux-${GO_ARCH}.tar.gz -P ${GITLAB_BUILD_DIR}/
  tar -xf ${GITLAB_BUILD_DIR}/go${GOLANG_VERSION}.linux-${GO_ARCH}.tar.gz -C /tmp/
fi

# gitaly
if ! [ -e /usr/local/bin/gitaly ]; then
  # download and build gitaly
  if ! [ -d ${GITLAB_GITALY_BUILD_DIR} ]; then
    echo "Downloading gitaly v${GITALY_SERVER_VERSION}..."
    git clone -q -b v${GITALY_SERVER_VERSION} --depth 1 ${GITLAB_GITALY_URL} ${GITLAB_GITALY_BUILD_DIR}
  fi 

  # 设置编译环境变量，禁用会导致问题的警告
  bundle config build.grpc --with-system-libraries
  bundle config mirror.https://rubygems.org https://mirrors.tuna.tsinghua.edu.cn/rubygems

  # install gitaly
  export CFLAGS="${CFLAGS} -Wno-error=stringop-overflow -Wno-error=sizeof-pointer-memaccess -Wno-error"
  export CXXFLAGS="${CXXFLAGS} -Wno-error=stringop-overflow -Wno-error=sizeof-pointer-memaccess -Wno-error"
  export GRPC_RUBY_COMPILE_PLATFORM_ONLY=true
  make -C ${GITLAB_GITALY_BUILD_DIR} install
  
  mkdir -p ${GITLAB_GITALY_INSTALL_DIR}
  cp -a ${GITLAB_GITALY_BUILD_DIR}/ruby ${GITLAB_GITALY_INSTALL_DIR}/
  cp -a ${GITLAB_GITALY_BUILD_DIR}/config.toml.example ${GITLAB_GITALY_INSTALL_DIR}/config.toml
  rm -rf ${GITLAB_GITALY_INSTALL_DIR}/ruby/vendor/bundle/ruby/**/cache

  # clean up
  rm -rf ${GITLAB_GITALY_BUILD_DIR}

  # Fix for rebase in forks 
  echo "Linking $(command -v gitaly-ssh) to /"
  ln -s "$(command -v gitaly-ssh)" /
fi
