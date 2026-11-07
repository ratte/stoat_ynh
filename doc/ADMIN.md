## Components

| Service | Role |
|---|---|
| `__APP__-api` | REST API (delta), port 14702 |
| `__APP__-events` | WebSocket events (bonfire), port 14703 |
| `__APP__-autumn` | File uploads, port 14704 |
| `__APP__-january` | Link previews / image proxy, port 14705 |
| `__APP__-gifbox` | GIF picker proxy (Tenor), port 14706 |
| `__APP__-crond` | Cleanup jobs |
| `__APP__-pushd` | Push notifications |
| `__APP__-voice-ingress` | LiveKit webhook receiver, port 8500 |
| `__APP__-livekit` | Voice/video server |
| `__APP__-garage` | S3 object storage for uploads |

Logs are in `/var/log/__APP__/`.

## Configuration

`__INSTALL_DIR__/Revolt.toml` is regenerated on every upgrade. Put your own settings in `__DATA_DIR__/Revolt.overrides.toml` (same format; it is merged over the base file), then restart the services:

```bash
for s in api events autumn january gifbox crond pushd voice-ingress; do systemctl restart __APP__-$s; done
```

Useful overrides:

```toml
# Email verification (without it, accounts are usable right away)
[api.smtp]
host = "smtp.example.com"
username = "user"
password = "secret"
from_address = "noreply@__DOMAIN__"
port = 587
use_tls = true

# GIF picker
[api.security]
tenor_key = "YOUR_TENOR_KEY"

# Only these user IDs may create servers
[features.limits.global]
restrict_server_creation = ["01ABC..."]
```

## Invite-only registration

If invite-only mode is enabled, create an invite code directly in MongoDB:

```bash
mongosh revolt --eval 'db.invites.insertOne({ _id: "my-invite-code", used: false })'
```

## Upload size

Uploads are limited to 20 MB by default (`[features.limits.*.file_upload_size_limit]`). nginx accepts up to 25 MB; if you raise the Stoat limit, also raise `client_max_body_size` in `/etc/nginx/conf.d/__DOMAIN__.d/__APP__.conf`.
