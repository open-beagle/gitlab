#!/bin/bash
set -ex

sed -i -e 's/deb.debian.org/archive.debian.org/g' \
       -e 's|security.debian.org|archive.debian.org|g' \
       -e '/-updates/d' /etc/apt/sources.list

apt-get update 

DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    wget curl ca-certificates apt-transport-https software-properties-common \
    sudo supervisor logrotate locales \
    openssh-server default-mysql-client postgresql-client redis-tools \
    libgpgme11 libmariadb-dev gettext-base shared-mime-info gawk bison libtool sqlite3 gnupg2 \
    git python2.7

# --- Nginx (官方源) ---
wget --quiet -O - https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/debian/ buster nginx" > /etc/apt/sources.list.d/nginx.list
# PostgreSQL
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg
echo 'deb http://apt-archive.postgresql.org/pub/repos/apt/ buster-pgdg main' > /etc/apt/sources.list.d/pgdg.list 
# Yarn
curl -fsSL https://dl.yarnpkg.com/debian/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/yarn-archive-keyring.gpg
echo 'deb https://dl.yarnpkg.com/debian/ stable main' > /etc/apt/sources.list.d/yarn.list 

# --- 安装构建时依赖 ---
apt-get update 
DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        nginx \
        yarn 

# --- 清理 ---
rm -rf /var/lib/apt/lists/* /tmp/*