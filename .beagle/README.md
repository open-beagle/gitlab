# gitlab

<https://github.com/sameersbn/docker-gitlab>

```bash
git remote add upstream git@github.com:sameersbn/docker-gitlab.git

git fetch upstream

git merge 11.11.3
```

## build

```bash
# debug
docker run -it --rm \
-v ${PWD}:/go/src/github.com/open-beagle/gitlab \
registry.cn-qingdao.aliyuncs.com/wod/ubuntu:20.04-amd64 \
bash

# amd64
docker buildx build \
  --platform linux/amd64 \
  --build-arg BASE=registry.cn-qingdao.aliyuncs.com/wod/ubuntu:20.04-amd64 \
  --tag registry.cn-qingdao.aliyuncs.com/wod/gitlab:v11.11.3-amd64 \
  -f .beagle/Dockerfile \
  --load .

# arm64
docker buildx build \
  --platform linux/arm64 \
  --build-arg BASE=registry.cn-qingdao.aliyuncs.com/wod/ubuntu:xenial-arm64 \
  --tag registry.cn-qingdao.aliyuncs.com/wod/gitlab:v11.11.3-arm64 \
  -f .beagle/arm64.Dockerfile \
  --load .
```

## mysql

```bash
docker pull sameersbn/redis:4.0.9-1 && \
docker tag sameersbn/redis:4.0.9-1 registry.cn-qingdao.aliyuncs.com/wod/redis:4.0.9-sameersbn && \
docker push registry.cn-qingdao.aliyuncs.com/wod/redis:4.0.9-sameersbn

docker run --name gitlab-redis -d \
    --volume ./.tmp/redis:/var/lib/redis \
    registry.cn-qingdao.aliyuncs.com/wod/redis:4.0.9-sameersbn

docker rm -f gitlab-redis

docker pull sameersbn/mysql:5.7.22-1 && \
docker tag sameersbn/mysql:5.7.22-1 registry.cn-qingdao.aliyuncs.com/wod/mysql:5.7.22-sameersbn && \
docker push registry.cn-qingdao.aliyuncs.com/wod/mysql:5.7.22-sameersbn

docker run --name gitlab-mysql -d \
    --env 'DB_NAME=gitlabhq_production' \
    --env 'DB_USER=gitlab' --env 'DB_PASS=password' \
    --volume ./.tmp/mysql:/var/lib/mysql \
    registry.cn-qingdao.aliyuncs.com/wod/mysql:5.7.22-sameersbn

docker rm -f gitlab-mysql

docker pull registry.cn-qingdao.aliyuncs.com/wod/gitlab:v11.11.3-amd64 && \
docker run \
    --name gitlab \
    --link gitlab-mysql:mysql \
    --link gitlab-redis:redisio \
    -it \
    --rm \
    --volume ./.tmp/gitlab:/home/git/data \
    -v ./assets/runtime:/etc/docker-gitlab/runtime \
    --publish 10022:22 --publish 10080:80 \
    --env 'GITLAB_PORT=10080' --env 'GITLAB_SSH_PORT=10022' \
    --env 'GITLAB_SECRETS_DB_KEY_BASE=long-and-random-alpha-numeric-string' \
    --env 'GITLAB_SECRETS_SECRET_KEY_BASE=long-and-random-alpha-numeric-string' \
    --env 'GITLAB_SECRETS_OTP_KEY_BASE=long-and-random-alpha-numeric-string' \
    registry.cn-qingdao.aliyuncs.com/wod/gitlab:v11.11.3-amd64

docker rm -f gitlab
```
