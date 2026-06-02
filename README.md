# wgsh.sh

`wgsh.sh` is a small Bash tool for managing WireGuard configuration files and keys in a local directory tree. It generates server-side interface configuration, peer configuration, peer QR codes, and rendered interface configs without directly applying anything to the running system.

It is a WireGuard configuration generator, not a host configurator.

The script can be used as a normal CLI command, or with no arguments as a small interactive REPL.

## Features

- Create and update WireGuard interfaces without overwriting existing keys during updates.
- Create and update peers with separate peer-side and server-side `AllowedIPs`.
- Render a server interface config from enabled peers.
- Temporarily disable peers without deleting their keys or config files.
- Delete only disabled peers, as a safety guard.
- Show peer config files and terminal QR codes for mobile clients.
- Detect peer IP conflicts with other peers and the interface gateway IP.

## Requirements

- Bash
- Standard Unix utilities: `awk`, `basename`, `cat`, `grep`, `mkdir`, `rm`, `sed`
- WireGuard tools, specifically `wg`
- Optional: `qrencode` for `show-peer-qr`

`wg` is required for commands that inspect, create, update, render, or show WireGuard config data. `help`, `-h`, and `--help` can be displayed without `wg`. `qrencode` is required only for `show-peer-qr`.

## Installation

Make sure the script is executable:

```sh
chmod +x wgsh.sh
```

Run it directly:

```sh
./wgsh.sh help
```

## Configuration Root

`wgsh.sh` stores all generated files under `WG_SH2_HOME`. If `WG_SH2_HOME` is not set, the current working directory is used.

```sh
WG_SH2_HOME=./vpn ./wgsh.sh create-interface wg0 10.0.0.1 vpn.example.com 51820
```

## Directory Layout

For an interface named `wg0` and a peer named `phone`, the layout is:

```text
wg0/
  interface/
    interface.conf
    private.key
    public.key
  peers/
    phone/
      peer.conf
      interface.conf
      private.key
      public.key
      disabled
```

The `disabled` file is present only when the peer is disabled.

## Quick Start

Create an interface:

```sh
./wgsh.sh create-interface wg0 10.0.0.1 vpn.example.com 51820
```

Create a peer:

```sh
./wgsh.sh create-peer wg0 phone 10.0.0.2 -pa 0.0.0.0/0 -ia 192.168.1.0/24 --dns 1.1.1.1
```

List peers:

```sh
./wgsh.sh list-peers wg0
```

Example output:

```text
phone 10.0.0.2 enabled
```

Render the server-side interface configuration:

```sh
./wgsh.sh render-interface wg0
```

Write the rendered config to `/etc/wireguard` yourself if you want to use it as a system WireGuard config:

```sh
./wgsh.sh render-interface wg0 | sudo tee /etc/wireguard/wg0.conf >/dev/null
sudo chmod 600 /etc/wireguard/wg0.conf
```

Show the peer config:

```sh
./wgsh.sh show-peer wg0 phone
```

Show a terminal QR code for the peer config:

```sh
./wgsh.sh show-peer-qr wg0 phone
```

## Command Reference

```text
list-interfaces
create-interface IF_NAME GW_IP_ADDR HOST PORT [options]
update-interface IF_NAME GW_IP_ADDR HOST PORT [options]
list-peers IF_NAME
create-peer IF_NAME PEER_NAME IP_ADDR [options]
update-peer IF_NAME PEER_NAME IP_ADDR [options]
disable-peer IF_NAME PEER_NAME
enable-peer IF_NAME PEER_NAME
delete-peer IF_NAME PEER_NAME
show-interface IF_NAME
render-interface IF_NAME
show-peer IF_NAME PEER_NAME
show-peer-interface IF_NAME PEER_NAME
show-peer-qr IF_NAME PEER_NAME
help
exit
quit
```

### Interface Options

These options are accepted by `create-interface` and `update-interface`:

```text
--mtu VALUE
```

Adds an `MTU` line to the server-side `interface.conf`.

### Peer Options

These options are accepted by `create-peer` and `update-peer`:

```text
--peer-allowed-ips VALUE
--pa VALUE
-pa VALUE
```

Adds an extra `AllowedIPs` line to the peer-side `peer.conf`. The interface gateway IP derived `/24` is always included by default.

```text
--interface-allowed-ips VALUE
--ia VALUE
-ia VALUE
```

Adds an extra `AllowedIPs` line to the server-side peer `interface.conf`. The peer IP `/32` is always included by default.

```text
--dns VALUE
```

Adds a `DNS` line to the peer-side `peer.conf`.

```text
--mtu VALUE
```

Adds an `MTU` line to the peer-side `peer.conf`.

## Create vs Update

`create-interface` and `create-peer` are for new resources only. They fail if the target interface or peer already exists.

`update-interface` and `update-peer` regenerate configuration files for existing resources without changing existing `private.key` or `public.key` files.

Before updating, `update-interface` and `update-peer` print a `CURRENT` / `NEW` summary without private keys so optional values that will be removed by omitted options are visible before confirmation.

When `update-interface` changes the endpoint or gateway IP, existing peer `peer.conf` files are regenerated so that:

- `Endpoint` follows the new interface endpoint.
- The default peer-side `AllowedIPs` follows the new gateway IP derived `/24`.
- Existing peer DNS, peer MTU, peer-side extra `AllowedIPs`, and server-side extra `AllowedIPs` entries are preserved.

## AllowedIPs Behavior

For a command like:

```sh
./wgsh.sh create-interface wg0 10.0.0.1 vpn.example.com 51820
./wgsh.sh create-peer wg0 phone 10.0.0.2 -pa 0.0.0.0/0 -ia 192.168.1.0/24
```

The peer-side `peer.conf` contains:

```ini
AllowedIPs = 10.0.0.0/24
AllowedIPs = 0.0.0.0/0
```

The server-side peer `interface.conf` contains:

```ini
AllowedIPs = 10.0.0.2/32
AllowedIPs = 192.168.1.0/24
```

## Peer Lifecycle

Disable a peer:

```sh
./wgsh.sh disable-peer wg0 phone
```

Disabled peers remain on disk, but `render-interface` does not include them.

Enable a peer:

```sh
./wgsh.sh enable-peer wg0 phone
```

Delete a peer:

```sh
./wgsh.sh delete-peer wg0 phone
```

`delete-peer` only deletes peers that are already disabled. This is intentional: disable first, confirm the rendered interface no longer includes the peer, then delete.

## Rendering and Showing Configs

`render-interface` prints the server-side configuration for an interface by combining:

- `IF_NAME/interface/interface.conf`
- enabled peer `IF_NAME/peers/PEER_NAME/interface.conf` files

It writes to standard output only.

`show-interface` prints only the base interface config:

```sh
./wgsh.sh show-interface wg0
```

`show-peer` prints the client-side peer config:

```sh
./wgsh.sh show-peer wg0 phone
```

`show-peer-interface` prints the server-side peer fragment:

```sh
./wgsh.sh show-peer-interface wg0 phone
```

`show-peer-qr` prints a terminal QR code for the client-side peer config:

```sh
./wgsh.sh show-peer-qr wg0 phone
```

## Writing Rendered Configs

`wgsh.sh` never writes to `/etc/wireguard` by itself. If you want to use a rendered interface config as a system WireGuard config, write it explicitly:

```sh
./wgsh.sh render-interface wg0 | sudo tee /etc/wireguard/wg0.conf >/dev/null
sudo chmod 600 /etc/wireguard/wg0.conf
```

Review the rendered config before applying it to a host. Routing, firewall, NAT, and service management are outside the scope of this tool.

## Non-goals

`wgsh.sh` does not manage host-level networking or service state. It does not:

- run `wg-quick up` or `wg-quick down`
- create or enable `systemd` units
- configure `sysctl` or IP forwarding
- generate `iptables`, `nftables`, firewall, or NAT rules
- install OS packages
- automatically write files under `/etc/wireguard`

## Interactive Mode

Run the script without arguments to start the REPL:

```sh
./wgsh.sh
```

Empty input or an unknown command prints help. Use `exit`, `quit`, or `Ctrl-D` to leave the REPL.

## Safety Notes

- This tool generates and renders configuration files. It does not run `wg-quick up`, `wg-quick down`, or apply configuration to the OS.
- Applying rendered configs, routing, firewall, NAT, and service integration are the user's responsibility.
- If `wg` is missing, commands that operate on config data fail with `wg not found, exiting...`.
- If `qrencode` is missing, only `show-peer-qr` fails.
- `private.key` and `public.key` files are created only during `create-interface` and `create-peer`.
- `update-interface` and `update-peer` do not regenerate keys.
- Peer IPs must be inside the interface gateway IP `/24`.
- Peer IPs cannot conflict with the interface gateway IP or another peer IP.
- Metadata such as `# IF_IP_ADDR:` and `# PEER_IP_ADDR:` is stored as comments in generated config files. WireGuard ignores these comments, but the script uses them for management.

## Author

MATSUOKA Hiroshi <matsuboyjr@gmail.com>

GitHub: [@matsuboyjr](https://github.com/matsuboyjr)

## License

MIT License. See [LICENSE](LICENSE) for details.
