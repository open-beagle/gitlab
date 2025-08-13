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
  libgrpc-dev libgrpc++-dev protobuf-compiler-grpc libssh2-1-dev \
  autoconf automake libsqlite3-dev"

## Execute a command as GITLAB_USER
exec_as_git() {
  if [[ $(whoami) == "${GITLAB_USER}" ]]; then
    "$@"
  else
    # 使用 -l (login) 标志启动一个登录式的shell，
    # 这会强制加载 /home/git/.profile 文件，从而初始化RVM环境
    sudo -HEu ${GITLAB_USER} bash -l -c 'exec "$@"' sh-as-git "$@"
  fi
}

# install build dependencies for gem installation
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y ${BUILD_DEPENDENCIES}

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
echo "Cloning gitlab-ce v${GITLAB_VERSION}..."
exec_as_git git clone -q --depth 1 --branch v${GITLAB_VERSION} ${GITLAB_CLONE_URL} ${GITLAB_INSTALL_DIR}

GITLAB_SHELL_VERSION=${GITLAB_SHELL_VERSION:-$(cat ${GITLAB_INSTALL_DIR}/GITLAB_SHELL_VERSION)}
GITLAB_WORKHORSE_VERSION=${GITLAB_WORKHORSE_VERSION:-$(cat ${GITLAB_INSTALL_DIR}/GITLAB_WORKHORSE_VERSION)}
GITLAB_PAGES_VERSION=${GITLAB_PAGES_VERSION:-$(cat ${GITLAB_INSTALL_DIR}/GITLAB_PAGES_VERSION)}

# download golang
echo "Downloading Go ${GOLANG_VERSION}..."
wget -cnv https://storage.googleapis.com/golang/go${GOLANG_VERSION}.linux-${GO_ARCH}.tar.gz -P ${GITLAB_BUILD_DIR}/
tar -xf ${GITLAB_BUILD_DIR}/go${GOLANG_VERSION}.linux-${GO_ARCH}.tar.gz -C /tmp/

# install gitlab-shell
echo "Downloading gitlab-shell v${GITLAB_SHELL_VERSION}..."
mkdir -p ${GITLAB_SHELL_INSTALL_DIR}
wget -cq ${GITLAB_SHELL_URL} -O ${GITLAB_BUILD_DIR}/gitlab-shell-${GITLAB_SHELL_VERSION}.tar.bz2
tar xf ${GITLAB_BUILD_DIR}/gitlab-shell-${GITLAB_SHELL_VERSION}.tar.bz2 --strip 1 -C ${GITLAB_SHELL_INSTALL_DIR}
rm -rf ${GITLAB_BUILD_DIR}/gitlab-shell-${GITLAB_SHELL_VERSION}.tar.bz2
chown -R ${GITLAB_USER}: ${GITLAB_SHELL_INSTALL_DIR}

cd ${GITLAB_SHELL_INSTALL_DIR}
exec_as_git cp -a config.yml.example config.yml

# 检查 ./bin/compile 是否存在且可执行
if [[ -x ./bin/compile ]]; then
  echo "Compiling gitlab-shell golang executables..."
  # 以 git 用户身份运行编译
  exec_as_git ./bin/compile
fi

# 以 git 用户身份运行安装 
exec_as_git ./bin/install

# remove unused repositories directory created by gitlab-shell install
rm -rf ${GITLAB_HOME}/repositories

# download gitlab-workhorse
echo "Cloning gitlab-workhorse v${GITLAB_WORKHORSE_VERSION}..."
git clone -q -b v${GITLAB_WORKHORSE_VERSION} --depth 1 ${GITLAB_WORKHORSE_URL} ${GITLAB_WORKHORSE_BUILD_DIR}
make -C ${GITLAB_WORKHORSE_BUILD_DIR} install

# clean up
rm -rf ${GITLAB_WORKHORSE_BUILD_DIR}

# download gitlab-pages
echo "Downloading gitlab-pages v${GITLAB_PAGES_VERSION}..."
git clone -q -b v${GITLAB_PAGES_VERSION} --depth 1 ${GITLAB_PAGES_URL} ${GITLAB_PAGES_BUILD_DIR}

# install gitlab-pages
make -C ${GITLAB_PAGES_BUILD_DIR}
cp -a ${GITLAB_PAGES_BUILD_DIR}/gitlab-pages /usr/local/bin/

# clean up
rm -rf ${GITLAB_PAGES_BUILD_DIR}

rm -rf ${GITLAB_GITALY_BUILD_DIR}
# download and build gitaly
echo "Downloading gitaly v${GITALY_SERVER_VERSION}..."
git clone -q -b v${GITALY_SERVER_VERSION} --depth 1 ${GITLAB_GITALY_URL} ${GITLAB_GITALY_BUILD_DIR}

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

# clean up
rm -rf ${GITLAB_GITALY_BUILD_DIR}

# remove go
rm -rf ${GITLAB_BUILD_DIR}/go${GOLANG_VERSION}.linux-${GO_ARCH}.tar.gz ${GOROOT}

# Fix for rebase in forks 
echo "Linking $(command -v gitaly-ssh) to /"
ln -s "$(command -v gitaly-ssh)" /

# remove HSTS config from the default headers, we configure it in nginx
exec_as_git sed -i "/headers\['Strict-Transport-Security'\]/d" ${GITLAB_INSTALL_DIR}/app/controllers/application_controller.rb

# revert `rake gitlab:setup` changes from gitlabhq/gitlabhq@a54af831bae023770bf9b2633cc45ec0d5f5a66a
exec_as_git sed -i 's/db:reset/db:setup/' ${GITLAB_INSTALL_DIR}/lib/tasks/gitlab/setup.rake

cd ${GITLAB_INSTALL_DIR}

# --- 在这里加入针对 gpgme 的修复 ---
echo "INFO: Configuring bundler to use system libraries for gpgme gem..."
exec_as_git bundle config build.gpgme --use-system-libraries
# --- 修复结束 ---

# --- ADD THE FIX HERE ---
# Fix for the yanked mimemagic gem version
echo "INFO: Fixing mimemagic gem issue..."

# 修复 bundle 权限问题
chown -R ${GITLAB_USER}: ${GITLAB_HOME}
exec_as_git bundle config set --local path 'vendor/bundle'
exec_as_git bundle config set --local without 'development test aws'

# 尝试修复 mimemagic 问题
if ! exec_as_git bundle lock --update mimemagic 2>/dev/null; then
    echo "INFO: mimemagic update failed, trying to remove problematic version..."
    # 尝试移除有问题的 mimemagic 版本并重新生成 Gemfile.lock
    exec_as_git sed -i '/mimemagic (0.3.2)/d' Gemfile.lock || true
    exec_as_git sed -i '/mimemagic (~> 0.3.2)/d' Gemfile.lock || true
    
    # 如果还是失败，跳过这个步骤
    echo "INFO: Continuing without mimemagic update..."
fi
# --- END OF FIX ---

# install gems, use local cache if available
if [[ -d ${GEM_CACHE_DIR} ]]; then
  mv ${GEM_CACHE_DIR} ${GITLAB_INSTALL_DIR}/vendor/cache
  chown -R ${GITLAB_USER}: ${GITLAB_INSTALL_DIR}/vendor/cache
fi

# 确保正确的权限和配置
chown -R ${GITLAB_USER}: ${GITLAB_INSTALL_DIR}
exec_as_git bundle config set --local deployment 'true'
exec_as_git bundle config set --local path 'vendor/bundle'
exec_as_git bundle config set --local without 'development test aws'

# 安装 gems
exec_as_git bundle install

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

# remove auto generated ${GITLAB_DATA_DIR}/config/secrets.yml
rm -rf ${GITLAB_DATA_DIR}/config/secrets.yml

# remove gitlab shell and workhorse secrets
rm -f ${GITLAB_INSTALL_DIR}/.gitlab_shell_secret ${GITLAB_INSTALL_DIR}/.gitlab_workhorse_secret

exec_as_git mkdir -p ${GITLAB_INSTALL_DIR}/tmp/pids/ ${GITLAB_INSTALL_DIR}/tmp/sockets/
chmod -R u+rwX ${GITLAB_INSTALL_DIR}/tmp

# symlink ${GITLAB_HOME}/.ssh -> ${GITLAB_LOG_DIR}/gitlab
rm -rf ${GITLAB_HOME}/.ssh
exec_as_git ln -sf ${GITLAB_DATA_DIR}/.ssh ${GITLAB_HOME}/.ssh

# symlink ${GITLAB_INSTALL_DIR}/log -> ${GITLAB_LOG_DIR}/gitlab
rm -rf ${GITLAB_INSTALL_DIR}/log
ln -sf ${GITLAB_LOG_DIR}/gitlab ${GITLAB_INSTALL_DIR}/log

# symlink ${GITLAB_INSTALL_DIR}/public/uploads -> ${GITLAB_DATA_DIR}/uploads
rm -rf ${GITLAB_INSTALL_DIR}/public/uploads
exec_as_git ln -sf ${GITLAB_DATA_DIR}/uploads ${GITLAB_INSTALL_DIR}/public/uploads

# symlink ${GITLAB_INSTALL_DIR}/.secret -> ${GITLAB_DATA_DIR}/.secret
rm -rf ${GITLAB_INSTALL_DIR}/.secret
exec_as_git ln -sf ${GITLAB_DATA_DIR}/.secret ${GITLAB_INSTALL_DIR}/.secret

# WORKAROUND for https://github.com/sameersbn/docker-gitlab/issues/509
rm -rf ${GITLAB_INSTALL_DIR}/builds
rm -rf ${GITLAB_INSTALL_DIR}/shared

# install gitlab bootscript, to silence gitlab:check warnings
cp ${GITLAB_INSTALL_DIR}/lib/support/init.d/gitlab /etc/init.d/gitlab
chmod +x /etc/init.d/gitlab

# disable default nginx configuration and enable gitlab's nginx configuration
rm -rf /etc/nginx/sites-enabled/default

# configure sshd
sed -i \
  -e "s|^[#]*UsePAM yes|UsePAM no|" \
  -e "s|^[#]*UsePrivilegeSeparation yes|UsePrivilegeSeparation no|" \
  -e "s|^[#]*PasswordAuthentication yes|PasswordAuthentication no|" \
  -e "s|^[#]*LogLevel INFO|LogLevel VERBOSE|" \
  -e "s|^[#]*AuthorizedKeysFile.*|AuthorizedKeysFile %h/.ssh/authorized_keys %h/.ssh/authorized_keys_proxy|" \
  /etc/ssh/sshd_config
echo "UseDNS no" >> /etc/ssh/sshd_config

# move supervisord.log file to ${GITLAB_LOG_DIR}/supervisor/
sed -i "s|^[#]*logfile=.*|logfile=${GITLAB_LOG_DIR}/supervisor/supervisord.log ;|" /etc/supervisor/supervisord.conf

# move nginx logs to ${GITLAB_LOG_DIR}/nginx
sed -i \
  -e "s|access_log /var/log/nginx/access.log;|access_log ${GITLAB_LOG_DIR}/nginx/access.log;|" \
  -e "s|error_log /var/log/nginx/error.log;|error_log ${GITLAB_LOG_DIR}/nginx/error.log;|" \
  /etc/nginx/nginx.conf

# fix "unknown group 'syslog'" error preventing logrotate from functioning
sed -i "s|^su root syslog$|su root root|" /etc/logrotate.conf

# configure supervisord log rotation
cat > /etc/logrotate.d/supervisord <<EOF
${GITLAB_LOG_DIR}/supervisor/*.log {
  weekly
  missingok
  rotate 52
  compress
  delaycompress
  notifempty
  copytruncate
}
EOF

# configure gitlab log rotation
cat > /etc/logrotate.d/gitlab <<EOF
${GITLAB_LOG_DIR}/gitlab/*.log {
  weekly
  missingok
  rotate 52
  compress
  delaycompress
  notifempty
  copytruncate
}
EOF

# configure gitlab-shell log rotation
cat > /etc/logrotate.d/gitlab-shell <<EOF
${GITLAB_LOG_DIR}/gitlab-shell/*.log {
  weekly
  missingok
  rotate 52
  compress
  delaycompress
  notifempty
  copytruncate
}
EOF

# configure gitlab vhost log rotation
cat > /etc/logrotate.d/gitlab-nginx <<EOF
${GITLAB_LOG_DIR}/nginx/*.log {
  weekly
  missingok
  rotate 52
  compress
  delaycompress
  notifempty
  copytruncate
}
EOF

# configure supervisord to start unicorn
cat > /etc/supervisor/conf.d/unicorn.conf <<EOF
[program:unicorn]
priority=10
directory=${GITLAB_INSTALL_DIR}
environment=HOME=${GITLAB_HOME}
command=/bin/bash -l -c "bundle exec unicorn_rails -c ${GITLAB_INSTALL_DIR}/config/unicorn.rb -E ${RAILS_ENV}"
user=git
autostart=true
autorestart=true
stopsignal=QUIT
stdout_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# configure supervisord to start sidekiq
cat > /etc/supervisor/conf.d/sidekiq.conf <<EOF
[program:sidekiq]
priority=10
directory=${GITLAB_INSTALL_DIR}
environment=HOME=${GITLAB_HOME}
command=/bin/bash -l -c "bundle exec sidekiq -c {{SIDEKIQ_CONCURRENCY}} \
  -C ${GITLAB_INSTALL_DIR}/config/sidekiq_queues.yml \
  -e ${RAILS_ENV} \
  -t {{SIDEKIQ_SHUTDOWN_TIMEOUT}} \
  -P ${GITLAB_INSTALL_DIR}/tmp/pids/sidekiq.pid \
  -L ${GITLAB_INSTALL_DIR}/log/sidekiq.log"
user=git
autostart=true
autorestart=true
stdout_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# configure supervisord to start gitlab-workhorse
cat > /etc/supervisor/conf.d/gitlab-workhorse.conf <<EOF
[program:gitlab-workhorse]
priority=20
directory=${GITLAB_INSTALL_DIR}
environment=HOME=${GITLAB_HOME}
command=/usr/local/bin/gitlab-workhorse
  -listenUmask 0
  -listenNetwork tcp
  -listenAddr ":8181"
  -authBackend http://127.0.0.1:8080{{GITLAB_RELATIVE_URL_ROOT}}
  -authSocket ${GITLAB_INSTALL_DIR}/tmp/sockets/gitlab.socket
  -documentRoot ${GITLAB_INSTALL_DIR}/public
  -proxyHeadersTimeout {{GITLAB_WORKHORSE_TIMEOUT}}
user=git
autostart=true
autorestart=true
stdout_logfile=${GITLAB_INSTALL_DIR}/log/%(program_name)s.log
stderr_logfile=${GITLAB_INSTALL_DIR}/log/%(program_name)s.log
EOF

# configure supervisord to start gitaly
cat > /etc/supervisor/conf.d/gitaly.conf <<EOF
[program:gitaly]
priority=5
directory=${GITLAB_GITALY_INSTALL_DIR}
environment=HOME=${GITLAB_HOME}
command=/bin/bash -l -c "/usr/local/bin/gitaly ${GITLAB_GITALY_INSTALL_DIR}/config.toml"
user=git
autostart=true
autorestart=true
stdout_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# configure supervisord to start mail_room
cat > /etc/supervisor/conf.d/mail_room.conf <<EOF
[program:mail_room]
priority=20
directory=${GITLAB_INSTALL_DIR}
environment=HOME=${GITLAB_HOME}
command=/bin/bash -l -c "bundle exec mail_room -c ${GITLAB_INSTALL_DIR}/config/mail_room.yml"
user=git
autostart={{GITLAB_INCOMING_EMAIL_ENABLED}}
autorestart=true
stdout_logfile=${GITLAB_INSTALL_DIR}/log/%(program_name)s.log
stderr_logfile=${GITLAB_INSTALL_DIR}/log/%(program_name)s.log
EOF

# configure supervisor to start sshd
mkdir -p /var/run/sshd
cat > /etc/supervisor/conf.d/sshd.conf <<EOF
[program:sshd]
directory=/
command=/usr/sbin/sshd -D -E ${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
user=root
autostart=true
autorestart=true
stdout_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# configure supervisord to start nginx
cat > /etc/supervisor/conf.d/nginx.conf <<EOF
[program:nginx]
priority=20
directory=/tmp
command=/usr/sbin/nginx -g "daemon off;"
user=root
autostart=true
autorestart=true
stdout_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# configure supervisord to start crond
cat > /etc/supervisor/conf.d/cron.conf <<EOF
[program:cron]
priority=20
directory=/tmp
command=/usr/sbin/cron -f
user=root
autostart=true
autorestart=true
stdout_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
stderr_logfile=${GITLAB_LOG_DIR}/supervisor/%(program_name)s.log
EOF

# purge build dependencies and cleanup apt
DEBIAN_FRONTEND=noninteractive apt-get purge -y --auto-remove ${BUILD_DEPENDENCIES}
rm -rf /var/lib/apt/lists/*

# clean up caches
exec_as_git rm -rf ${GITLAB_HOME}/.cache
