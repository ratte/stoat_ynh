# stoat_ynh – context for Claude Code

YunoHost package (packaging v2, helpers 2.1) for Stoat (formerly Revolt) v0.15.5.
Goal: inclusion in the YunoHost app catalog. Repo: github.com/ratte/stoat_ynh.
Communicate with the user in German.

## Architecture (native, no Docker)
- MongoDB 8.0 via `ynh_install_mongo`, db name `revolt`, user `$app`
- Redis (system redis-server, free db index), RabbitMQ (apt, user `$app` on vhost `/`)
- Garage (S3) for uploads, bucket `revolt-uploads`, binary from `dxflrs/garage:v2.3.0`
- LiveKit from `ghcr.io/stoatchat/livekit-server:v1.9.14`, single-port mode (TCP 7881, UDP 7882)
- Stoat binaries + ffmpeg/ffprobe from `ghcr.io/stoatchat/*:v0.15.5`, web client from `ghcr.io/stoatchat/for-web:4017c18`
- Stoat images are distroless Debian 13: binaries at `/home/nonroot/revolt-*`, need glibc 2.39 → their
  `usr/lib/<triplet>` is shipped as `$install_dir/lib` and `patchelf` points loader + RPATH there
- `for-web` exists only for amd64 (static, fetched as amd64 on every arch)
- Images are fetched by `_oci_extract` in `scripts/_common.sh` (registry v2 API, layers sha256-verified),
  because YunoHost's vendored docker-image-extract only supports Docker Hub (PR YunoHost/yunohost#2293 pending)
- Web client: placeholders `__VITE_*__` in the built dist are replaced by `_stoat_build_web` (mirrors upstream docker/inject.js)
- Upstream ports are hard-coded (14702–14706, 8500) → `fixed = true` in manifest, `multi_instance = false`
- Admin overrides: `$data_dir/Revolt.overrides.toml`, symlinked into `$install_dir`

## Testing
- VM: `cd dev && vagrant up && vagrant snapshot save clean`
- Install: `vagrant rsync && vagrant ssh -c "sudo yunohost app install /stoat_ynh -a 'domain=chat.stoat.test&init_main_permission=visitors&invite_only=0&enable_video=1' --force --debug"`
- Reset: `vagrant snapshot restore clean`
- CI: `.github/workflows/package_check.yml` runs YunoHost package_check (untested on GitHub runners yet)
- Logs on the VM: `/var/log/stoat/*.log`, `journalctl -u stoat-*`

## Unverified assumptions – check first
1. `/livekit-server` and `/garage` are statically linked (stoat images confirmed for amd64+arm64)
2. Garage v2 CLI in `_stoat_setup_garage`: `node id -q`, `status` showing "NO ROLE ASSIGNED", `layout assign/apply`, `key import --yes`, `bucket allow`
3. MongoDB database name `revolt`; Revolt.toml keys `key`/`secret` under `[api.livekit.nodes.worldwide]`
4. (verified) for-web has no video flag, video is switched in Revolt.toml; `__VITE_HOST__` must be the domain
   (empty falls back to stoat.chat); unset placeholders become `void 0` like inject.js
5. `Revolt.overrides.toml` is read in production
6. autumn finds ffmpeg via PATH (verified: bonfire honours `HOST`; delta/autumn/january/gifbox/voice-ingress
   hard-code 0.0.0.0:<port>, env cannot change it)
7. `ynh_config_remove_systemd`, `ynh_redis_remove_db` take positional args in helpers 2.1

## Conventions
- Commit messages in English; keep scripts `bash -n` clean
- Don't add a path question: Stoat must live at a domain root
