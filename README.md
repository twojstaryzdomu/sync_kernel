# sync_kernel
Run `rpi-update` once and distribute the updated kernel to many RPis.

Since `rpi-update` kernels are not delivered as DEB packages,
it is safe and the result is identical to running `rpi-update`
on the updated RPi itself. Backup of files modified is written
in case recovery is needed.

## How to run

### Prerequisites
1. The script requires `ksh`. If not yet installed, install it with:
```
# sudo apt-get install ksh
```
2. Make sure `sudo` works for the `pi` user. This script can be run
by `pi` without `sudo` since it `sudo`'s to `root` internally as required.

3. Configure passwordless logins from `pi` to `root` & `pi` on the remote host.
Use `# ssh-copy-id <remote username>@<remote hostname>`.

The default `sshd` settings may need to be modified before
remote authentication with an ssh key is possible for `root`.

Note the logins need to work from both ends, especially for
the push mode as it runs `rsync` from the remote end.

Here's my sshd set up:

RPi running Debian bookworm:

```
# cat /etc/ssh/sshd_config
Include /etc/ssh/sshd_config.d/*.conf
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem       sftp    /usr/lib/openssh/sftp-server
# cat /etc/ssh/sshd_config.d/*
/etc/ssh/sshd_config.d/disable_root_password.conf:PermitRootLogin prohibit-password
/etc/ssh/sshd_config.d/disable_strict.conf:StrictModes no
/etc/ssh/sshd_config.d/enable_pubkey.conf:PubkeyAuthentication yes
```

RPi running Debian buster:

```
# cat /etc/ssh/sshd_config
PermitRootLogin prohibit-password
StrictModes no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem       sftp    /usr/lib/openssh/sftp-server
```

## Running the script

1. Pull the lastest kernel with `# rpi-update` onto an RPi. Reboot it.
2. Copy the script to either environment.
3. Sync up the kernel to another RPi from either end (as user `pi` or `root`):
```
# ./sync_kernel.ksh <hostname to pull kernel from>
```
or
```
# ./sync_kernel.ksh <hostname to push kernel to>
```
The script will determine the sync direction based on which host
is running a more recent kernel.

4. Boot to new kernel.
5. Remove the stale kernel module directories manually from `/lib/modules`.
`# dpkg -S raspberrypi-kernel` will tell you which directories come from the
DEB packaged kernel, which you might want to keep.

## Notes
It is safe to run it when both kernels match:
```
USER = pi, HOST = rpi1 => LOCAL = pi@rpi1, LOCAL_ARCH = armv6l, LOCAL_KERNEL = 5.15.50+
REMOTE_USER = , REMOTE_HOST = rpi2 => REMOTE = pi@rpi2, REMOTE_ARCH = armv7l, REMOTE_KERNEL = 5.15.50-v7+
Syncing latest kernel to pi@rpi2
Checking currently installed kernel version (it might take a while)... 5.15.50+
Hosts rpi1 & rpi2 running the same kernel 5.15.50
```

Backup is written to `/dev/shm/backup`, which does not persist over 
a reboot. Feel free to modify the `BACKUP_DIR` variable as needed.

In DHCP environments, running the script as
`# DISABLE_STRICT=1 ./sync_kernel.ksh <hostname>` might help with ssh warnings
about IPs not matching when those change frequently. A better way to address it
would be to remove IPs from `~/.ssh/authorized_keys` and replace them with
`<user>@<hostname>` entries.

