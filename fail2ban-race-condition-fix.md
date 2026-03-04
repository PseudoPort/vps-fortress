# Fail2ban Startup Race Condition Fix

## Problem
The fail2ban systemd service experiences a race condition where fail2ban-client 
tries to connect to the socket too quickly after the server starts, before the 
socket is fully ready.

## Symptoms (from logs)
- Mar 03 09:31:17 fail2ban-server started successfully ("Server ready")
- Mar 03 09:31:18 fail2ban-client failed with "Failed to access socket path: 
  /var/run/fail2ban/fail2ban.sock. Is fail2ban running?"
- This caused systemd fail2ban.service to fail with 
  "Control process exited, code=exited, status=255/EXCEPTION"

## Root Cause
The systemd service's ExecStartPost directive runs fail2ban-client immediately 
after the server process starts, but before the Unix socket 
(/var/run/fail2ban/fail2ban.sock) is fully created. The server logs 
"Server ready" when it begins listening, but socket file creation can lag 
by a few hundred milliseconds.

## Solution
Create a systemd override to wait for socket availability before running 
fail2ban-client:

### Option 1: Wait for Socket with Retry Loop (Recommended)
```bash
mkdir -p /etc/systemd/system/fail2ban.service.d

cat > /etc/systemd/system/fail2ban.service.d/override.conf << 'EOF'
[Service]
ExecStartPost=/bin/bash -c 'for i in {1..30}; do test -S /var/run/fail2ban/fail2ban.sock && break; sleep 0.5; done; /usr/bin/fail2ban-client ping || exit 1'
EOF
```

This loops up to 15 seconds checking for the socket file before running 
fail2ban-client, ensuring the server is truly ready.

### Option 2: Simple Fixed Delay
```bash
mkdir -p /etc/systemd/system/fail2ban.service.d

cat > /etc/systemd/system/fail2ban.service.d/override.conf << 'EOF'
[Service]
ExecStartPost=/bin/sleep 2 && /usr/bin/fail2ban-client ping
EOF
```

## Apply the Fix
```bash
systemctl daemon-reload
systemctl restart fail2ban
systemctl status fail2ban
```

## Verify
Check the logs to confirm successful startup:
```bash
journalctl -u fail2ban -n 20
```

The fix ensures that the fail2ban-client only runs after the socket is 
confirmed to exist, preventing the race condition on service start or reboot.
