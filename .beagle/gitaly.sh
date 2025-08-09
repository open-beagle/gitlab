#!/bin/bash
set -ex

GITLAB_HOME=${PWD}/.tmp
GITLAB_USER=${user}

GITLAB_GITALY_URL=https://gitlab.com/gitlab-org/gitaly.git
GITALY_SERVER_VERSION=1.42.7

GITLAB_GITALY_BUILD_DIR=${GITLAB_HOME}/src/gitaly
GITLAB_GITALY_INSTALL_DIR="${GITLAB_HOME}/gitaly"

GOROOT=/tmp/go
GOLANG_VERSION=1.12.6
PATH=${GOROOT}/bin:$PATH

# 1. 修正 APT 源，指向 Debian 10 Buster 的官方归档 (Archive)
sed -i -e 's/deb.debian.org/archive.debian.org/g' \
       -e 's|security.debian.org|archive.debian.org|g' \
       -e '/-updates/d' /etc/apt/sources.list

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    build-essential git gnupg2 curl wget ca-certificates \
    cmake \
    libgrpc-dev libgrpc++-dev protobuf-compiler-grpc libssh2-1-dev

# --- 关键修复：从源码编译并安装指定版本的 libgit2 ---
echo "INFO: Building libgit2 v0.28.5 from source to satisfy rugged gem..."
LIBGIT2_VERSION="0.28.5"
cd /tmp
wget -q https://github.com/libgit2/libgit2/archive/v${LIBGIT2_VERSION}.tar.gz -O libgit2.tar.gz
tar xzf libgit2.tar.gz
cd libgit2-${LIBGIT2_VERSION}/
mkdir build && cd build
# 我们将它安装到 /usr/local，这是一个标准位置
cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local
cmake --build . --target install
cd / # 返回根目录以避免路径问题
# --- 修复结束 ---

# download golang
# 检测系统架构并设置Go语言对应的架构名称
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
if ! [[ -d ${GOROOT} ]]; then
  echo "Downloading Go ${GOLANG_VERSION}..."
  wget -cnv https://storage.googleapis.com/golang/go${GOLANG_VERSION}.linux-${GO_ARCH}.tar.gz -P /tmp/
  tar -xf /tmp/go${GOLANG_VERSION}.linux-${GO_ARCH}.tar.gz -C /tmp/
fi

# # download and build gitaly
if ! [[ -d ${GITLAB_GITALY_BUILD_DIR} ]]; then
  echo "Downloading gitaly v.${GITALY_SERVER_VERSION}..."
  git clone -q -b v${GITALY_SERVER_VERSION} --depth 1 ${GITLAB_GITALY_URL} ${GITLAB_GITALY_BUILD_DIR}
fi

# --- 关键修复：在 make 之前，强制更新 Gitaly 的 grpc gem 版本 ---
echo "INFO: Hacking Gitaly's Gemfile.lock to update grpc for ARM64 compatibility..."
cd ${GITLAB_GITALY_BUILD_DIR}/ruby
# 以 git 用户身份执行 bundle lock --update
# 这会尝试将 grpc 更新到最新的 1.x 版本，这些新版本通常有更好的ARM64支持
bundle config build.grpc --with-system-libraries
# 告诉 bundler 在安装 rugged 时也使用系统库
bundle config build.rugged --use-system-libraries
bundle lock --update grpc
cd ${GITLAB_HOME}
# --- 修复结束 ---

# install gitaly
# 使用 rvm exec 来确保 make 命令及其所有子进程都运行在正确的 Ruby 环境中
make -C ${GITLAB_GITALY_BUILD_DIR} install
mkdir -p ${GITLAB_GITALY_INSTALL_DIR}
cp -a ${GITLAB_GITALY_BUILD_DIR}/ruby ${GITLAB_GITALY_INSTALL_DIR}/
cp -a ${GITLAB_GITALY_BUILD_DIR}/config.toml.example ${GITLAB_GITALY_INSTALL_DIR}/config.toml
rm -rf ${GITLAB_GITALY_INSTALL_DIR}/ruby/vendor/bundle/ruby/**/cache

# # clean up
# rm -rf ${GITLAB_GITALY_BUILD_DIR}