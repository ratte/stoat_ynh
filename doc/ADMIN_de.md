## Komponenten

| Dienst | Aufgabe |
|---|---|
| `__APP__-api` | REST-API (delta), Port 14702 |
| `__APP__-events` | WebSocket-Events (bonfire), Port 14703 |
| `__APP__-autumn` | Datei-Uploads, Port 14704 |
| `__APP__-january` | Link-Vorschauen / Bild-Proxy, Port 14705 |
| `__APP__-gifbox` | GIF-Auswahl-Proxy (Tenor), Port 14706 |
| `__APP__-crond` | Aufräumjobs |
| `__APP__-pushd` | Push-Benachrichtigungen |
| `__APP__-voice-ingress` | LiveKit-Webhook-Empfänger, Port 8500 |
| `__APP__-livekit` | Sprach-/Videoserver |
| `__APP__-garage` | S3-Objektspeicher für Uploads |

Logs liegen in `/var/log/__APP__/`.

## Konfiguration

`__INSTALL_DIR__/Revolt.toml` wird bei jedem Upgrade neu geschrieben. Eigene Einstellungen gehören in `__DATA_DIR__/Revolt.overrides.toml` (gleiches Format, wird über die Basisdatei gelegt). Danach die Dienste neu starten:

```bash
for s in api events autumn january gifbox crond pushd voice-ingress; do systemctl restart __APP__-$s; done
```

Beispiele (SMTP, Tenor-Key, Servererstellung einschränken) siehe englische Admin-Doku.

## Registrierung nur mit Einladung

Ist der Einladungsmodus aktiv, legst du Codes direkt in MongoDB an:

```bash
mongosh revolt --eval 'db.invites.insertOne({ _id: "mein-einladungscode", used: false })'
```

## Upload-Grösse

Standard sind 20 MB pro Datei. nginx akzeptiert bis 25 MB; wer das Stoat-Limit erhöht, muss auch `client_max_body_size` in `/etc/nginx/conf.d/__DOMAIN__.d/__APP__.conf` anpassen.
