# gitlab

<https://github.com/sameersbn/docker-gitlab>

```bash
git remote add upstream git@github.com:sameersbn/docker-gitlab.git

git fetch upstream

git merge 11.11.3
```

## build

```bash
# amd64
docker buildx build \
  --platform linux/amd64 \
  --build-arg BASE=registry.cn-qingdao.aliyuncs.com/wod/ubuntu:xenial-amd64 \
  --tag registry.cn-qingdao.aliyuncs.com/wod/gitlab:11.11.3-amd64 \
  -f .beagle/Dockerfile \
  --load .

# arm64
docker buildx build \
  --platform linux/arm64 \
  --build-arg BASE=registry.cn-qingdao.aliyuncs.com/wod/ubuntu:xenial-arm64 \
  --tag registry.cn-qingdao.aliyuncs.com/wod/gitlab:11.11.3-arm64 \
  -f .beagle/Dockerfile \
  --load .
```
