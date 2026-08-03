# Deployment

## Building for Production

```bash
zig build -Doptimize=ReleaseSmall
```

This produces a stripped native binary at `zig-out/bin/zs3`. A static
x86-64 Linux build is under 360KB:

```bash
zig build -Dtarget=x86_64-linux-musl \
  -Dcpu=baseline -Doptimize=ReleaseSmall
```

## Cross-Compilation

Build for Linux from any platform:

```bash
# x86_64
zig build -Dtarget=x86_64-linux-musl -Dcpu=baseline -Doptimize=ReleaseSmall

# ARM64
zig build -Dtarget=aarch64-linux-musl -Dcpu=baseline -Doptimize=ReleaseSmall
```

The binary is statically linked and has no dependencies.

## Running

```bash
./zs3
```

Server listens on port 9000 by default. Data stored in `./data/`.

## Systemd Service

```ini
# /etc/systemd/system/zs3.service
[Unit]
Description=zs3 S3-compatible storage
After=network.target

[Service]
Type=simple
User=zs3
Group=zs3
WorkingDirectory=/var/lib/zs3
ExecStart=/usr/local/bin/zs3
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo useradd -r -s /bin/false zs3
sudo mkdir -p /var/lib/zs3/data
sudo chown -R zs3:zs3 /var/lib/zs3
sudo cp zig-out/bin/zs3 /usr/local/bin/
sudo systemctl enable --now zs3
```

## Docker

```dockerfile
FROM alpine:latest
COPY zs3 /usr/local/bin/zs3
WORKDIR /data
EXPOSE 9000
CMD ["/usr/local/bin/zs3"]
```

```bash
zig build -Dtarget=x86_64-linux-musl -Dcpu=baseline -Doptimize=ReleaseSmall
docker build -t zs3 .
docker run -p 9000:9000 -v ./data:/data zs3
```

## Docker Compose

```yaml
version: '3'
services:
  zs3:
    build: .
    ports:
      - "9000:9000"
    volumes:
      - ./data:/data
    restart: unless-stopped
```

## Reverse Proxy with TLS

### Caddy (automatic HTTPS)

```
s3.example.com {
    reverse_proxy localhost:9000
}
```

### nginx

```nginx
server {
    listen 443 ssl http2;
    server_name s3.example.com;

    ssl_certificate /etc/letsencrypt/live/s3.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/s3.example.com/privkey.pem;

    client_max_body_size 5G;

    location / {
        proxy_pass http://127.0.0.1:9000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
```

## Health Check

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:9000/
# Returns 403 (no auth) - server is up
```

## Backup

Data is stored as regular files:

```bash
# Backup
tar -czf backup.tar.gz data/

# Restore
tar -xzf backup.tar.gz
```

## Monitoring

zs3 logs to stderr:

```
info: S3 server listening on http://0.0.0.0:9000
error: Connection error: ...
```

Redirect to file or use systemd journal:

```bash
./zs3 2>&1 | tee -a /var/log/zs3.log
```
