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
    build-essential git cmake curl wget ca-certificates \
    gnupg2 \
    libgrpc-dev libgrpc++-dev protobuf-compiler-grpc libssh2-1-dev

# --- 关键修复：从源码编译并安装指定版本的 libgit2，并避免重复安装 ---
LIBGIT2_VERSION="0.28.5"
INSTALLED_VERSION=$(pkg-config --modversion libgit2 2>/dev/null || echo "not found")
if [ "$INSTALLED_VERSION" = "$LIBGIT2_VERSION" ]; then
    echo "INFO: libgit2 v${LIBGIT2_VERSION} is already installed. Skipping build."
else
    echo "INFO: libgit2 v${LIBGIT2_VERSION} not found or version mismatch (found: ${INSTALLED_VERSION}). Building from source..."
    cd /tmp
    wget -q https://github.com/libgit2/libgit2/archive/v${LIBGIT2_VERSION}.tar.gz -O libgit2.tar.gz
    tar xzf libgit2.tar.gz
    cd libgit2-${LIBGIT2_VERSION}/
    mkdir build && cd build
    # 我们将它安装到 /usr/local，这是一个标准位置
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local
    cmake --build . --target install
    # 更新动态链接器缓存，非常重要！
    ldconfig
    cd / # 返回根目录以避免路径问题
    # 清理下载和解压的临时文件
    rm -rf /tmp/libgit2.tar.gz /tmp/libgit2-${LIBGIT2_VERSION}
    ldconfig # 刷新动态链接库缓存，非常重要！
    echo "INFO: libgit2 v${LIBGIT2_VERSION} installed successfully."
fi
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
  echo "Downloading gitaly v${GITALY_SERVER_VERSION}..."
  git clone -q -b v${GITALY_SERVER_VERSION} --depth 1 ${GITLAB_GITALY_URL} ${GITLAB_GITALY_BUILD_DIR}
fi

# --- 关键修复：ARM64 grpc gem 编译问题 ---
echo "INFO: Preparing ARM64-compatible grpc gem compilation..."
cd "${GITLAB_GITALY_BUILD_DIR}/ruby"

# 设置编译环境变量，禁用会导致问题的警告
export CFLAGS="${CFLAGS} -Wno-error=stringop-overflow -Wno-error=sizeof-pointer-memaccess -Wno-error"
export CXXFLAGS="${CXXFLAGS} -Wno-error=stringop-overflow -Wno-error=sizeof-pointer-memaccess -Wno-error"

# 配置bundler使用系统库
bundle config build.grpc --with-system-libraries
bundle config build.rugged --use-system-libraries

# 设置 GRPC 编译环境变量
export GRPC_RUBY_COMPILE_PLATFORM_ONLY=true

# 尝试安装依赖
echo "INFO: Installing Ruby dependencies with ARM64 compatibility fixes..."
bundle install

# 检查grpc gem是否已经成功安装
if bundle list | grep -q "grpc (1.19.0)"; then
    echo "INFO: grpc gem 1.19.0 installed successfully!"
else
    echo "ERROR: grpc gem 1.19.0 installation failed."
    exit 1
fi

echo "INFO: Bundle install completed successfully for ARM64!"
cd ${GITLAB_HOME}
# --- ARM64修复结束 ---

# install gitaly
# 使用 rvm exec 来确保 make 命令及其所有子进程都运行在正确的 Ruby 环境中
make -C ${GITLAB_GITALY_BUILD_DIR} install
mkdir -p ${GITLAB_GITALY_INSTALL_DIR}
cp -a ${GITLAB_GITALY_BUILD_DIR}/ruby ${GITLAB_GITALY_INSTALL_DIR}/
cp -a ${GITLAB_GITALY_BUILD_DIR}/config.toml.example ${GITLAB_GITALY_INSTALL_DIR}/config.toml
rm -rf ${GITLAB_GITALY_INSTALL_DIR}/ruby/vendor/bundle/ruby/**/cache

# # clean up
# rm -rf ${GITLAB_GITALY_BUILD_DIR}