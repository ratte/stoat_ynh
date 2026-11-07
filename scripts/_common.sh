#!/bin/bash

#=================================================
# COMMON VARIABLES AND CUSTOM HELPERS
#=================================================

# MongoDB version installed by ynh_install_mongo
mongo_version="8.0"

# Pinned upstream images (stoatchat/self-hosted compose.yml)
stoat_version="v0.15.5"
stoat_web_ref="4017c18"           # for-web v0.15.3
livekit_ref="v1.9.14"
garage_ref="v2.3.0"

# component name -> image
declare -A stoat_images=(
    [api]="stoatchat/api"
    [events]="stoatchat/events"
    [autumn]="stoatchat/file-server"
    [january]="stoatchat/proxy"
    [gifbox]="stoatchat/gifbox"
    [crond]="stoatchat/crond"
    [pushd]="stoatchat/pushd"
    [voice-ingress]="stoatchat/voice-ingress"
)

# All systemd units of this app, in start order
stoat_units=(garage livekit api events autumn january gifbox crond pushd voice-ingress)

_oci_arch() {
    case "$YNH_ARCH" in
        amd64) echo "amd64" ;;
        arm64) echo "arm64" ;;
        *) ynh_die "Unsupported architecture: $YNH_ARCH" ;;
    esac
}

# Multiarch triplet and dynamic loader name of the upstream (Debian-based) images
_oci_triplet() {
    case "$YNH_ARCH" in
        amd64) echo "x86_64-linux-gnu" ;;
        arm64) echo "aarch64-linux-gnu" ;;
    esac
}
_oci_loader() {
    case "$YNH_ARCH" in
        amd64) echo "ld-linux-x86-64.so.2" ;;
        arm64) echo "ld-linux-aarch64.so.1" ;;
    esac
}

# Download an OCI/Docker image from a registry and unpack its filesystem.
# Every layer is verified against its sha256 digest from the manifest.
#
# usage: _oci_extract <registry> <image> <tag> <dest_dir> [arch]
_oci_extract() {
    local registry="$1" image="$2" ref="$3" dest="$4"
    local arch api token_url token manifest digest layer tmp
    arch="${5:-$(_oci_arch)}"

    if [ "$registry" = "docker.io" ]; then
        api="https://registry-1.docker.io"
        token_url="https://auth.docker.io/token?service=registry.docker.io&scope=repository:${image}:pull"
    else
        api="${_OCI_SCHEME:-https}://${registry}"
        token_url="${api}/token?service=${registry}&scope=repository:${image}:pull"
    fi

    token="$(curl -fsSL --retry 3 "$token_url" | jq -r '.token // .access_token')"
    [ -n "$token" ] && [ "$token" != "null" ] || ynh_die "Could not get a registry token for $registry/$image"

    local accept="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

    manifest="$(curl -fsSL --retry 3 -H "Authorization: Bearer $token" -H "Accept: $accept" \
        "$api/v2/$image/manifests/$ref")" || ynh_die "Could not fetch manifest for $registry/$image:$ref"

    if jq -e '.manifests' >/dev/null <<<"$manifest"; then
        digest="$(jq -r --arg a "$arch" \
            '[.manifests[] | select(.platform.os=="linux" and .platform.architecture==$a)][0].digest // empty' <<<"$manifest")"
        [ -n "$digest" ] || ynh_die "$registry/$image:$ref has no linux/$arch image"
        manifest="$(curl -fsSL --retry 3 -H "Authorization: Bearer $token" -H "Accept: $accept" \
            "$api/v2/$image/manifests/$digest")" || ynh_die "Could not fetch $arch manifest for $registry/$image:$ref"
    fi

    mkdir -p "$dest"
    for layer in $(jq -r '.layers[].digest' <<<"$manifest"); do
        tmp="$(mktemp)"
        curl -fsSL --retry 3 -H "Authorization: Bearer $token" -o "$tmp" "$api/v2/$image/blobs/$layer" \
            || { rm -f "$tmp"; ynh_die "Download of layer $layer failed"; }
        if ! echo "${layer#sha256:}  $tmp" | sha256sum --check --status; then
            rm -f "$tmp"
            ynh_die "Checksum mismatch for layer $layer of $registry/$image:$ref"
        fi
        tar -xf "$tmp" -C "$dest" --no-same-owner --exclude='dev/*' \
            || { rm -f "$tmp"; ynh_die "Could not unpack layer $layer"; }
        rm -f "$tmp"
        # Apply whiteouts of this layer
        find "$dest" -name '.wh.*' -print0 | while IFS= read -r -d '' wh; do
            local base; base="$(basename "$wh")"
            if [ "$base" = ".wh..wh..opq" ]; then
                rm -f "$wh"
            else
                rm -rf "$(dirname "$wh")/${base#.wh.}" "$wh"
            fi
        done
    done
}

# Download all upstream components into $install_dir
_stoat_setup_sources() {
    local work comp bin triplet loader libdir
    work="$(mktemp -d)"
    triplet="$(_oci_triplet)"
    loader="$(_oci_loader)"
    libdir="$install_dir/lib"
    ynh_safe_rm "$install_dir/bin.new"
    ynh_safe_rm "$install_dir/lib.new"
    ynh_safe_rm "$install_dir/web.new"
    mkdir -p "$install_dir/bin.new" "$install_dir/lib.new" "$install_dir/web.new"

    # The Stoat binaries are built on Debian 13 (glibc >= 2.39, libdav1d7) while
    # YunoHost 12 runs on Debian 12: ship the images' runtime libraries along and
    # point the binaries' loader and RPATH to them.
    for comp in "${!stoat_images[@]}"; do
        ynh_print_info "Fetching $comp ($stoat_version)..."
        _oci_extract "ghcr.io" "${stoat_images[$comp]}" "$stoat_version" "$work/$comp"
        bin="$(find "$work/$comp/home/nonroot" -maxdepth 1 -type f -name 'revolt-*' 2>/dev/null | head -n1)"
        [ -n "$bin" ] || ynh_die "No revolt-* binary found in image ${stoat_images[$comp]}"
        [ -f "$work/$comp/usr/lib/$triplet/$loader" ] || ynh_die "No $loader found in image ${stoat_images[$comp]}"
        cp -an "$work/$comp/usr/lib/$triplet/." "$install_dir/lib.new/"
        install -m 0755 "$bin" "$install_dir/bin.new/stoat-$comp"
        patchelf --set-interpreter "$libdir/$loader" --force-rpath --set-rpath "$libdir" \
            "$install_dir/bin.new/stoat-$comp"
        if [ "$comp" = "autumn" ]; then
            # statically linked
            install -m 0755 "$work/$comp/usr/local/bin/ffmpeg" "$install_dir/bin.new/ffmpeg"
            install -m 0755 "$work/$comp/usr/local/bin/ffprobe" "$install_dir/bin.new/ffprobe"
        fi
        ynh_safe_rm "$work/$comp"
    done

    ynh_print_info "Fetching LiveKit ($livekit_ref)..."
    _oci_extract "ghcr.io" "stoatchat/livekit-server" "$livekit_ref" "$work/livekit"
    [ -f "$work/livekit/livekit-server" ] || ynh_die "livekit-server binary not found"
    install -m 0755 "$work/livekit/livekit-server" "$install_dir/bin.new/livekit-server"
    ynh_safe_rm "$work/livekit"

    ynh_print_info "Fetching Garage ($garage_ref)..."
    _oci_extract "docker.io" "dxflrs/garage" "$garage_ref" "$work/garage"
    [ -f "$work/garage/garage" ] || ynh_die "garage binary not found"
    install -m 0755 "$work/garage/garage" "$install_dir/bin.new/garage"
    ynh_safe_rm "$work/garage"

    # The web client is static and only published for amd64
    ynh_print_info "Fetching web client ($stoat_web_ref)..."
    _oci_extract "ghcr.io" "stoatchat/for-web" "$stoat_web_ref" "$work/web" "amd64"
    [ -f "$work/web/app/dist/index.html" ] || ynh_die "Web client dist not found in image"
    cp -a "$work/web/app/dist/." "$install_dir/web.new/"
    ynh_safe_rm "$work"

    local dir
    for dir in bin lib; do
        ynh_safe_rm "$install_dir/$dir"
        mv "$install_dir/$dir.new" "$install_dir/$dir"
    done
    ynh_safe_rm "$install_dir/web.dist"
    mv "$install_dir/web.new" "$install_dir/web.dist"

    # Every bundled library must resolve from $install_dir/lib
    for comp in "${!stoat_images[@]}"; do
        if "$libdir/$loader" --list "$install_dir/bin/stoat-$comp" | grep -q "not found"; then
            "$libdir/$loader" --list "$install_dir/bin/stoat-$comp" >&2
            ynh_die "Missing libraries for stoat-$comp"
        fi
    done
}

# Render the web client from the pristine dist with this instance's URLs
_stoat_build_web() {
    local web="$install_dir/web"
    local base="https://$domain"
    local video="false"
    [ "${enable_video:-0}" -eq 1 ] && video="true"

    ynh_safe_rm "$web"
    cp -a "$install_dir/web.dist" "$web"

    find "$web" -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.html' -o -name '*.json' -o -name '*.webmanifest' -o -name '*.css' \) -print0 \
        | xargs -0 -r sed -i \
            -e "s#__VITE_API_URL__#$base/api#g" \
            -e "s#__VITE_WS_URL__#wss://$domain/ws#g" \
            -e "s#__VITE_MEDIA_URL__#$base/autumn#g" \
            -e "s#__VITE_PROXY_URL__#$base/january#g" \
            -e "s#__VITE_GIFBOX_URL__#$base/gifbox#g" \
            -e "s#__VITE_CFG_ENABLE_VIDEO__#$video#g" \
            -e "s#__VITE_HOST__##g" \
            -e "s#__VITE_RNNOISE_WORKLET_CDN_URL__##g"

    echo -n "{\"api\":\"$base/api\"}" > "$install_dir/stoat.json"

    chown -R "$app:www-data" "$web" "$install_dir/stoat.json"
    chmod -R u=rwX,g=rX,o= "$web"
    chmod 640 "$install_dir/stoat.json"
}

# Secrets generated once and kept in the app settings
_stoat_generate_secrets() {
    if [ -z "${vapid_private_key:-}" ]; then
        local pem; pem="$(mktemp)"
        openssl ecparam -name prime256v1 -genkey -noout -out "$pem"
        vapid_private_key="$(base64 -w0 "$pem" | tr -d '=')"
        vapid_public_key="$(openssl ec -in "$pem" -outform DER 2>/dev/null | tail --bytes 65 | base64 -w0 | tr '/+' '_-' | tr -d '=')"
        rm -f "$pem"
        ynh_app_setting_set --key=vapid_private_key --value="$vapid_private_key"
        ynh_app_setting_set --key=vapid_public_key --value="$vapid_public_key"
    fi
    if [ -z "${files_encryption_key:-}" ]; then
        files_encryption_key="$(printf '%s' "$(ynh_string_random --length=32)" | base64 -w0)"
        ynh_app_setting_set --key=files_encryption_key --value="$files_encryption_key"
    fi
    if [ -z "${livekit_key:-}" ]; then
        livekit_key="$(ynh_string_random --length=12 --filter='a-f0-9')"
        livekit_secret="$(ynh_string_random --length=48 --filter='a-f0-9')"
        ynh_app_setting_set --key=livekit_key --value="$livekit_key"
        ynh_app_setting_set --key=livekit_secret --value="$livekit_secret"
    fi
    if [ -z "${rabbit_pwd:-}" ]; then
        rabbit_pwd="$(ynh_string_random --length=32)"
        ynh_app_setting_set --key=rabbit_pwd --value="$rabbit_pwd"
    fi
    if [ -z "${garage_rpc_secret:-}" ]; then
        garage_rpc_secret="$(ynh_string_random --length=64 --filter='a-f0-9')"
        ynh_app_setting_set --key=garage_rpc_secret --value="$garage_rpc_secret"
    fi
    if [ -z "${s3_key_id:-}" ]; then
        s3_key_id="GK$(ynh_string_random --length=24 --filter='a-f0-9')"
        s3_secret_key="$(ynh_string_random --length=64 --filter='a-f0-9')"
        ynh_app_setting_set --key=s3_key_id --value="$s3_key_id"
        ynh_app_setting_set --key=s3_secret_key --value="$s3_secret_key"
    fi
}

# Ensure the RabbitMQ user exists with the current password
_stoat_setup_rabbitmq() {
    ynh_systemctl --service=rabbitmq-server --action=start
    if rabbitmqctl -q list_users | awk '{print $1}' | grep -qx "$app"; then
        rabbitmqctl -q change_password "$app" "$rabbit_pwd"
    else
        rabbitmqctl -q add_user "$app" "$rabbit_pwd"
    fi
    rabbitmqctl -q set_permissions -p / "$app" ".*" ".*" ".*"
    yunohost service add rabbitmq-server --description="RabbitMQ message broker" --log="/var/log/rabbitmq"
}

_garage() {
    "$install_dir/bin/garage" -c "$install_dir/garage.toml" "$@"
}

# Single-node layout, bucket and access key (idempotent)
_stoat_setup_garage() {
    local node i up=0
    # 'node id' only reads the local key; 'status' needs the RPC port to be up
    for i in $(seq 1 60); do
        if _garage status >/dev/null 2>&1; then
            up=1
            break
        fi
        sleep 1
    done
    [ "$up" -eq 1 ] || ynh_die "Garage did not come up"
    node="$(_garage node id -q | cut -d@ -f1)"
    [ -n "$node" ] || ynh_die "Could not read the Garage node id"

    if _garage status 2>/dev/null | grep -q "NO ROLE ASSIGNED"; then
        _garage layout assign -z dc1 -c 10G "$node"
        _garage layout apply --version 1
    fi
    _garage bucket info revolt-uploads >/dev/null 2>&1 || _garage bucket create revolt-uploads
    _garage key info "$s3_key_id" >/dev/null 2>&1 || _garage key import --yes -n "$app" "$s3_key_id" "$s3_secret_key"
    _garage bucket allow --read --write --owner revolt-uploads --key "$s3_key_id"
}

# Write every config file and systemd unit
_stoat_add_configs() {
    ynh_config_add --template="Revolt.toml" --destination="$install_dir/Revolt.toml"
    ynh_config_add --template="livekit.yml" --destination="$install_dir/livekit.yml"
    ynh_config_add --template="garage.toml" --destination="$install_dir/garage.toml"
    chown "$app:$app" "$install_dir/Revolt.toml" "$install_dir/livekit.yml" "$install_dir/garage.toml"
    chmod 400 "$install_dir/Revolt.toml" "$install_dir/livekit.yml" "$install_dir/garage.toml"

    # Admin-editable overrides live in the data dir so they survive upgrades and backups
    if [ ! -f "$data_dir/Revolt.overrides.toml" ]; then
        echo "# Your own Stoat settings (merged over Revolt.toml). Restart the $app-* services after editing." \
            > "$data_dir/Revolt.overrides.toml"
    fi
    chown "$app:$app" "$data_dir/Revolt.overrides.toml"
    chmod 600 "$data_dir/Revolt.overrides.toml"
    ln -sfn "$data_dir/Revolt.overrides.toml" "$install_dir/Revolt.overrides.toml"

    local unit svc_desc svc_exec svc_env svc_after
    for unit in "${stoat_units[@]}"; do
        svc_env=""
        svc_after="network.target"
        case "$unit" in
            garage)
                svc_desc="Stoat object storage (Garage)"
                svc_exec="$install_dir/bin/garage -c $install_dir/garage.toml server" ;;
            livekit)
                svc_desc="Stoat voice server (LiveKit)"
                svc_exec="$install_dir/bin/livekit-server --config $install_dir/livekit.yml"
                svc_after="network.target redis-server.service" ;;
            *)
                svc_desc="Stoat $unit"
                svc_exec="$install_dir/bin/stoat-$unit"
                svc_after="network.target mongod.service redis-server.service rabbitmq-server.service $app-garage.service" ;;
        esac
        # api, autumn, january, gifbox and voice-ingress hard-code 0.0.0.0:<fixed port>
        # upstream (ROCKET_ADDRESS is overridden too); those ports stay closed in
        # the YunoHost firewall and are only reached through nginx.
        case "$unit" in
            events) svc_env="HOST=127.0.0.1:$port_events" ;;
            autumn) svc_env="PATH=$install_dir/bin:/usr/local/bin:/usr/bin:/bin" ;;
        esac
        ynh_config_add_systemd --service="$app-$unit" --template="systemd.service"
        yunohost service add "$app-$unit" --description="$svc_desc" --log="/var/log/$app/$unit.log"
    done

    ynh_config_add_nginx
    ynh_config_add_logrotate
}

_stoat_systemctl_all() {
    local action="$1" unit
    if [ "$action" = "stop" ]; then
        local i
        for (( i=${#stoat_units[@]}-1; i>=0; i-- )); do
            ynh_systemctl --service="$app-${stoat_units[$i]}" --action=stop
        done
    else
        for unit in "${stoat_units[@]}"; do
            ynh_systemctl --service="$app-$unit" --action="$action"
        done
    fi
}

_stoat_remove_units() {
    local unit
    for unit in "${stoat_units[@]}"; do
        if yunohost service status "$app-$unit" >/dev/null 2>&1; then
            yunohost service remove "$app-$unit"
        fi
        ynh_config_remove_systemd "$app-$unit"
    done
}
