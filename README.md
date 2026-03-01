vps-fortress
============

A zero-trust foundational setup for hardening freshly provisioned Linux servers. Covers essential SSH configurations, user management, and firewall rules.

Interactive guide: https://gemini.google.com/share/bd00bde22788

When you spin up a new Virtual Private Server (VPS), it is immediately exposed to the public internet. Automated bots and malicious actors begin scanning and attempting brute-force attacks within minutes. This guide provides a "first things first" checklist to lock down your server and establish a secure baseline before you deploy any applications.

<img width="436" height="197" alt="Screenshot 2026-03-02 at 00 49 24" src="https://github.com/user-attachments/assets/b1ba8669-9c12-49eb-b4c8-90d1382da317" />

Prerequisites
-------------

-   A freshly installed Linux VPS (Ubuntu, Debian, CentOS, RHEL, AlmaLinux, or Arch Linux).

-   Root access to the server.

-   An SSH client installed on your local machine.

-   An SSH key pair generated on your local machine.

Step 1: Update System Packages
------------------------------

The very first action on a new server should be applying the latest security patches and package updates.

### Ubuntu / Debian

```
apt update && apt upgrade -y

```

### CentOS / RHEL / AlmaLinux / Rocky Linux

```
dnf update -y

```

### Arch Linux

```
pacman -Syu

```

Step 2: Create a Non-Root Sudo User
-----------------------------------

Operating as the `root` user is dangerous. You should create a standard user with administrative privileges (sudo) for daily operations.

Replace `username` with your desired username.

### Ubuntu / Debian

```
adduser username
usermod -aG sudo username

```

### CentOS / RHEL / AlmaLinux / Arch Linux

```
useradd -m username
passwd username
usermod -aG wheel username

```

Note: On some minimal CentOS/Arch installations, you may need to install `sudo` and uncomment the `%wheel` group line in the `/etc/sudoers` file using the `visudo` command.

Step 3: Configure SSH Key Authentication
----------------------------------------

Before disabling password logins, you must ensure your new user can log in using an SSH key.

1.  Switch to your new user:

```
su - username

```

2.  Create the SSH directory and set permissions:

```
mkdir -p ~/.ssh
chmod 700 ~/.ssh

```

3.  Add your local machine's public key to the `authorized_keys` file:

```
nano ~/.ssh/authorized_keys

```

*(Paste your public SSH key here, save, and exit)*

4.  Set permissions for the authorized_keys file:

```
chmod 600 ~/.ssh/authorized_keys

```

5.  Return to the root user configuration:

```
exit

```

Step 4: Harden SSH Configuration
--------------------------------

Now that you have key-based access for a non-root user, you need to secure the SSH daemon to prevent brute-force attacks.

Open the SSH configuration file:

```
nano /etc/ssh/sshd_config

```

Make the following changes to the file:

1.  Change the default SSH port (e.g., to 2222 or any port between 1024 and 65535):

```
Port 2222

```

2.  Disable root login:

```
PermitRootLogin no

```

3.  Disable password authentication:

```
PasswordAuthentication no

```

4.  Disable empty passwords (should be default, but good to verify):

```
PermitEmptyPasswords no

```

Save and exit the file. Do not restart the SSH service just yet, as we need to configure the firewall to allow the new port first.

Step 5: Configure the Firewall
------------------------------

You must explicitly allow traffic on your new SSH port and block everything else.

### Ubuntu / Debian (UFW)

```
apt install ufw -y
ufw default deny incoming
ufw default allow outgoing
ufw allow 2222/tcp
ufw enable

```

### CentOS / RHEL / AlmaLinux (Firewalld)

```
dnf install firewalld -y
systemctl start firewalld
systemctl enable firewalld
firewall-cmd --permanent --add-port=2222/tcp
firewall-cmd --permanent --remove-service=ssh
firewall-cmd --reload

```

### Arch Linux (UFW)

```
pacman -S ufw
systemctl enable --now ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 2222/tcp
ufw enable

```

Now that the firewall is configured to allow your custom SSH port, restart the SSH service to apply the hardening configurations from Step 4.

### Ubuntu / Debian

```
systemctl restart ssh

```

### CentOS / RHEL / Arch Linux

```
systemctl restart sshd

```

Important: Do not close your current terminal session. Open a new terminal on your local machine and verify you can log in with your new user and custom port:

`ssh -p 2222 username@your_server_ip`

Step 6: Install and Configure Fail2Ban
--------------------------------------

Fail2Ban monitors log files for too many failed login attempts and temporarily bans the offending IP addresses at the firewall level.

### Ubuntu / Debian

```
apt install fail2ban -y
systemctl enable --now fail2ban

```

### CentOS / RHEL / AlmaLinux

```
dnf install epel-release -y
dnf install fail2ban -y
systemctl enable --now fail2ban

```

### Arch Linux

```
pacman -S fail2ban
systemctl enable --now fail2ban

```

Configure Fail2Ban to protect your custom SSH port:

```
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
nano /etc/fail2ban/jail.local

```

Find the `[sshd]` section and update the port to match your custom SSH port:

```
[sshd]
enabled = true
port = 2222
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 3
bantime = 3600

```

Restart Fail2Ban to apply the changes:

```
systemctl restart fail2ban

```

Step 7: Enable Automatic Security Updates (Optional but Recommended)
--------------------------------------------------------------------

To ensure your server remains secure against newly discovered vulnerabilities, enable automatic security updates.

### Ubuntu / Debian

```
apt install unattended-upgrades -y
dpkg-reconfigure --priority=low unattended-upgrades

```

### CentOS / RHEL / AlmaLinux

```
dnf install dnf-automatic -y
nano /etc/dnf/automatic.conf

```

Change `apply_updates = no` to `apply_updates = yes`. Then enable the timer:

```
systemctl enable --now dnf-automatic.timer

```

License
-------

MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
