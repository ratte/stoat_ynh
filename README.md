# Stoat for YunoHost

[Stoat](https://stoat.chat) (formerly Revolt) packaged for YunoHost, running natively (no Docker):
MongoDB, Redis and RabbitMQ from the system, Garage as S3 storage, LiveKit for voice/video,
and the official Stoat binaries and web client taken from the upstream release images.

**Shipped version:** 0.15.5~ynh1

## Installation

```bash
sudo yunohost app install https://github.com/YOUR_ORG/stoat_ynh
```

See `doc/` for pre-install notes and administration.
