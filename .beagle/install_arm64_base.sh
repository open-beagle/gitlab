#!/bin/bash
set -ex

# --- 构建依赖安装 ---
# 步骤1：更新软件源配置
sed -i -e 's/deb.debian.org/archive.debian.org/g' \
    -e 's|security.debian.org|archive.debian.org|g' \
    -e '/-updates/d' /etc/apt/sources.list

# 步骤2：安装基础工具
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    ca-certificates curl gnupg2 wget git
rm -rf /var/lib/apt/lists/*

# 步骤3a：添加 Nginx 软件源
curl -fsSL https://nginx.org/keys/nginx_signing.key | apt-key add -
echo "deb http://nginx.org/packages/debian/ buster nginx" > /etc/apt/sources.list.d/nginx.list

# 步骤3b：添加 PostgreSQL 软件源
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
echo "deb http://apt-archive.postgresql.org/pub/repos/apt/ buster-pgdg main" > /etc/apt/sources.list.d/pgdg.list

# 步骤3c：跳过 Yarn 官方源，我们将通过 npm 安装

# 步骤4：安装主要软件包
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    software-properties-common sudo supervisor logrotate locales \
    apt-transport-https openssh-server gettext-base \
    shared-mime-info gawk bison libtool sqlite3 libgpgme11 libmariadb-dev \
    default-mysql-client postgresql-client redis-tools \
    python2.7
rm -rf /var/lib/apt/lists/*

# 步骤5：安装 Nginx 和通过 npm 安装 Yarn
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    nginx nodejs npm
npm install -g yarn
rm -rf /var/lib/apt/lists/* /tmp/*