#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 MATSUOKA Hiroshi
set -euo pipefail

WG_SH2_HOME=${WG_SH2_HOME:-$(pwd)}
HISTSIZE=1000
WG_SH2_INTERACTIVE=0

echo_warn(){
	echo "[warn] $*" >&2
}

echo_error(){
	echo "[error] $*" >&2
}

usage(){
	cat <<__USAGE__
Usage:
  $(basename "$0") [command] [args...]

Commands:
  list-interfaces
  create-interface IF_NAME GW_IP_ADDR HOST PORT [options]
  update-interface IF_NAME GW_IP_ADDR HOST PORT [options]
  list-peers IF_NAME
  create-peer IF_NAME PEER_NAME IP_ADDR [options]
  update-peer IF_NAME PEER_NAME IP_ADDR [options]
  edit-interface-include IF_NAME
  edit-peer-include IF_NAME PEER_NAME
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

create-interface/update-interface options:
  --mtu VALUE
      Add MTU to the server-side interface.conf.

create-peer/update-peer options:
  --peer-allowed-ips VALUE, --pa VALUE, -pa VALUE
      Add an extra AllowedIPs line to the peer-side peer.conf.
      The interface GW_IP /24 is always included by default.

  --interface-allowed-ips VALUE, --ia VALUE, -ia VALUE
      Add an extra AllowedIPs line to the server-side peer interface.conf.
      The peer IP /32 is always included by default.

  --dns VALUE
      Add DNS to the peer-side peer.conf.

  --mtu VALUE
      Add MTU to the peer-side peer.conf.

  --keepalive VALUE, --ka VALUE, -ka VALUE
      Add PersistentKeepalive to the peer-side peer.conf.
__USAGE__
}

confirm_yN(){
	if [ "$WG_SH2_INTERACTIVE" -eq 0 ];then
		return 0
	fi

	local ans=""
	while true;do
		read -r -p "[y/N]> " ans
		case "$ans" in
		[yY])
			return 0
		;;
		[nN])
			return 1
		;;
		*)
			echo "N"
			return 1
		;;
		esac
	done
}

require_wg_command(){
	if ! command -v wg >/dev/null 2>&1;then
		echo "wg not found, exiting..." >&2
		exit 1
	fi
}

conf_value(){
	local conf_file=$1
	local key=$2

	grep "^# *$key:" "$conf_file" | sed -e "s/^# *$key: *\(..*\)/\1/"
}

validate_name(){
	local kind=$1
	local name=$2

	case "$name" in
	""|.*|*/*)
		echo_error "invalid $kind name: $name"
		return 1
	;;
	esac

	if ! [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]];then
		echo_error "invalid $kind name: $name"
		return 1
	fi
}

validate_mtu(){
	local mtu=$1

	if ! [[ "$mtu" =~ ^[0-9]+$ ]] || [ "$mtu" -le 0 ];then
		echo_error "invalid MTU: $mtu"
		return 1
	fi
}

validate_keepalive(){
	local keepalive=$1

	if ! [[ "$keepalive" =~ ^[0-9]+$ ]];then
		echo_error "invalid PersistentKeepalive: $keepalive"
		return 1
	fi
}

create_wg_keys(){
	local target_dir=$1

	umask 077
	wg genkey > "$target_dir/private.key"
	wg pubkey > "$target_dir/public.key" < "$target_dir/private.key"
}

interface_dir(){
	local if_name=$1
	echo "$WG_SH2_HOME/$if_name/interface"
}

interface_file(){
	local if_name=$1
	echo "$(interface_dir "$if_name")/interface.conf"
}

interface_include_file(){
	local if_name=$1
	echo "$(interface_dir "$if_name")/include.conf"
}

peer_dir(){
	local if_name=$1
	local peer_name=$2
	echo "$WG_SH2_HOME/$if_name/peers/$peer_name"
}

peer_file(){
	local if_name=$1
	local peer_name=$2
	echo "$(peer_dir "$if_name" "$peer_name")/peer.conf"
}

peer_include_file(){
	local if_name=$1
	local peer_name=$2
	echo "$(peer_dir "$if_name" "$peer_name")/include.conf"
}

peer_interface_file(){
	local if_name=$1
	local peer_name=$2
	echo "$(peer_dir "$if_name" "$peer_name")/interface.conf"
}

peer_disabled_file(){
	local if_name=$1
	local peer_name=$2
	echo "$(peer_dir "$if_name" "$peer_name")/disabled"
}

peer_status(){
	local if_name=$1
	local peer_name=$2

	if [ -f "$(peer_disabled_file "$if_name" "$peer_name")" ];then
		echo "disabled"
	else
		echo "enabled"
	fi
}

require_interface(){
	local if_name=$1
	local if2_dir
	local if_file
	local private_key_file
	local public_key_file
	if2_dir=$(interface_dir "$if_name")
	if_file=$(interface_file "$if_name")
	private_key_file="$if2_dir/private.key"
	public_key_file="$if2_dir/public.key"

	if [ ! -d "$if2_dir" ];then
		echo_warn "$if2_dir not found, quit."
		return 1
	fi
	if [ ! -f "$if_file" ];then
		echo_warn "$if_file not found, quit."
		return 1
	fi
	if [ ! -f "$private_key_file" ];then
		echo_warn "$private_key_file not found, quit."
		return 1
	fi
	if [ ! -f "$public_key_file" ];then
		echo_warn "$public_key_file not found, quit."
		return 1
	fi
}

require_peer(){
	local if_name=$1
	local peer_name=$2
	local dir
	local file
	local private_key_file
	local public_key_file

	dir=$(peer_dir "$if_name" "$peer_name")
	file=$(peer_file "$if_name" "$peer_name")
	private_key_file="$dir/private.key"
	public_key_file="$dir/public.key"

	if [ ! -d "$dir" ];then
		echo_warn "$dir not found, quit."
		return 1
	fi
	if [ ! -f "$file" ];then
		echo_warn "$file not found, quit."
		return 1
	fi
	if [ ! -f "$private_key_file" ];then
		echo_warn "$private_key_file not found, quit."
		return 1
	fi
	if [ ! -f "$public_key_file" ];then
		echo_warn "$public_key_file not found, quit."
		return 1
	fi
}

print_interface_with_include(){
	local conf_file=$1
	local include_file=$2

	cat "$conf_file"
	if [ -f "$include_file" ];then
		cat "$include_file"
	fi
}

print_peer_with_include(){
	local conf_file=$1
	local include_file=$2
	local line
	local included=0

	while IFS= read -r line || [ -n "$line" ];do
		if [ "$included" -eq 0 ] && [ "$line" = "[Peer]" ];then
			if [ -f "$include_file" ];then
				cat "$include_file"
			fi
			included=1
		fi
		printf "%s\n" "$line"
	done < "$conf_file"

	if [ "$included" -eq 0 ] && [ -f "$include_file" ];then
		cat "$include_file"
	fi
}

edit_include_file(){
	local include_file=$1
	local include_dir
	include_dir=$(dirname "$include_file")

	if [ "$WG_SH2_INTERACTIVE" -eq 1 ];then
		if [ -z "${EDITOR:-}" ];then
			echo_error "EDITOR is not set."
			return 1
		fi
		mkdir -p "$include_dir"
		touch "$include_file"
		"$EDITOR" "$include_file"
		return
	fi

	echo "waiting for standard input to write $include_file..." >&2
	mkdir -p "$include_dir"
	cat > "$include_file"
}

find_peer_ip(){
	local if_name=$1
	local ip_addr=$2
	local except_peer=${3:-}
	local peers_dir="$WG_SH2_HOME/$if_name/peers"
	local peer=""
	local peer_if=""

	if [ ! -d "$peers_dir" ];then
		return 1
	fi

	for peer_if in "$peers_dir"/*/interface.conf;do
		if [ ! -f "$peer_if" ];then
			continue
		fi
		peer=${peer_if#"$peers_dir/"}
		peer=${peer%/interface.conf}
		if [ -n "$except_peer" ] && [ "$peer" = "$except_peer" ];then
			continue
		fi
		if [ "$(conf_value "$peer_if" "PEER_IP_ADDR" || true)" = "$ip_addr" ];then
			echo "$peer"
			return 0
		fi
	done

	return 1
}

extract_allowed_ips_after_first(){
	local conf_file=$1

	awk '
		/^AllowedIPs[[:space:]]*=/ {
			count++
			if (count > 1) {
				sub(/^[^=]*=[[:space:]]*/, "")
				print
			}
		}
	' "$conf_file"
}

extract_allowed_ips(){
	local conf_file=$1

	awk '
		/^AllowedIPs[[:space:]]*=/ {
			sub(/^[^=]*=[[:space:]]*/, "")
			print
		}
	' "$conf_file"
}

extract_dns(){
	local conf_file=$1

	awk '
		/^DNS[[:space:]]*=/ {
			sub(/^[^=]*=[[:space:]]*/, "")
			print
			exit
		}
	' "$conf_file"
}

extract_endpoint(){
	local conf_file=$1

	awk '
		/^Endpoint[[:space:]]*=/ {
			sub(/^[^=]*=[[:space:]]*/, "")
			print
			exit
		}
	' "$conf_file"
}

extract_mtu(){
	local conf_file=$1

	awk '
		/^MTU[[:space:]]*=/ {
			sub(/^[^=]*=[[:space:]]*/, "")
			print
			exit
		}
	' "$conf_file"
}

extract_keepalive(){
	local conf_file=$1

	awk '
		/^PersistentKeepalive[[:space:]]*=/ {
			sub(/^[^=]*=[[:space:]]*/, "")
			print
			exit
		}
	' "$conf_file"
}

join_lines(){
	local line
	local result=""

	while IFS= read -r line;do
		if [ -n "$result" ];then
			result="$result $line"
		else
			result=$line
		fi
	done

	echo "$result"
}

validate_peer_ip(){
	local if_name=$1
	local peer_name=$2
	local ip_addr=$3
	local allow_self=${4:-0}
	local if_file
	local if_ip_addr
	local if_ip_prefix
	local existing_peer

	if_file=$(interface_file "$if_name")
	if_ip_addr=$(conf_value "$if_file" "IF_IP_ADDR")
	if_ip_prefix=$(conf_value "$if_file" "IF_IP_PREFIX")

	if [ "${ip_addr%.*}" != "${if_ip_prefix%.*}" ];then
		echo_warn "$ip_addr not matches $if_ip_prefix , quit."
		return 1
	fi

	if [ "$ip_addr" = "$if_ip_addr" ];then
		echo_warn "$ip_addr conflicts with interface GW_IP, quit."
		return 1
	fi

	if [ "$allow_self" -eq 1 ];then
		existing_peer=$(find_peer_ip "$if_name" "$ip_addr" "$peer_name" || true)
	else
		existing_peer=$(find_peer_ip "$if_name" "$ip_addr" || true)
	fi
	if [ -n "$existing_peer" ];then
		echo_warn "$ip_addr already exists in peer $existing_peer, quit."
		return 1
	fi
}

validate_interface_ip(){
	local if_name=$1
	local ip_addr=$2
	local existing_peer

	existing_peer=$(find_peer_ip "$if_name" "$ip_addr" || true)
	if [ -n "$existing_peer" ];then
		echo_warn "$ip_addr conflicts with peer $existing_peer, quit."
		return 1
	fi
}

write_interface_conf(){
	local if_name=$1
	local ip_addr=$2
	local host=$3
	local port=$4
	local mtu=$5
	local if2_dir
	local if_file
	local ip_prefix

	if2_dir=$(interface_dir "$if_name")
	if_file=$(interface_file "$if_name")
	ip_prefix="${ip_addr%.*}"

	cat > "$if_file" <<__END_OF_CONF__
# $if_name.conf

# INTERFACE
# IF_IP_ADDR:$ip_addr
# IF_IP_PREFIX:$ip_prefix.
# IF_ENDPOINT:$host:$port
[Interface]
Address = $ip_addr/32
ListenPort = $port
PrivateKey = $(cat "$if2_dir/private.key")
__END_OF_CONF__
	if [ -n "$mtu" ];then
		cat >> "$if_file" <<__END_OF_CONF__
MTU = $mtu
__END_OF_CONF__
	fi
	cat >> "$if_file" <<__END_OF_CONF__

# CLIENTS

__END_OF_CONF__
}

write_peer_confs(){
	local if_name=$1
	local peer_name=$2
	local ip_addr=$3
	local if2_dir
	local if_file
	local peer_dir
	local peer_file
	local peer_if
	local if_ip_prefix
	local if_endpoint
	local default_peer_allowed_ips
	local allowed_ips

	if2_dir=$(interface_dir "$if_name")
	if_file=$(interface_file "$if_name")
	peer_dir=$(peer_dir "$if_name" "$peer_name")
	peer_file=$(peer_file "$if_name" "$peer_name")
	peer_if=$(peer_interface_file "$if_name" "$peer_name")
	if_ip_prefix=$(conf_value "$if_file" "IF_IP_PREFIX")
	if_endpoint=$(conf_value "$if_file" "IF_ENDPOINT")
	default_peer_allowed_ips="${if_ip_prefix%.*}.0/24"

	cat > "$peer_file" <<__PEER_CONF__
[Interface]
PrivateKey = $(cat "$peer_dir/private.key")
Address = $ip_addr/32
__PEER_CONF__
	if [ -n "$PEER_MTU" ];then
		cat >> "$peer_file" <<__PEER_CONF__
MTU = $PEER_MTU
__PEER_CONF__
	fi
	if [ -n "$PEER_DNS" ];then
		cat >> "$peer_file" <<__PEER_CONF__
DNS = $PEER_DNS
__PEER_CONF__
	fi

	cat >> "$peer_file" <<__PEER_CONF__

[Peer]
PublicKey = $(cat "$if2_dir/public.key")
Endpoint = $if_endpoint
AllowedIPs = $default_peer_allowed_ips
__PEER_CONF__

	for allowed_ips in "${PEER_ALLOWED_IPS[@]}";do
		cat >> "$peer_file" <<__PEER_CONF__
AllowedIPs = $allowed_ips
__PEER_CONF__
	done
	if [ -n "$PEER_KEEPALIVE" ];then
		cat >> "$peer_file" <<__PEER_CONF__
PersistentKeepalive = $PEER_KEEPALIVE
__PEER_CONF__
	fi

	cat > "$peer_if" <<__IF_CONF__
[Peer]
# PEER_NAME:$peer_name
# PEER_IP_ADDR:$ip_addr
PublicKey = $(cat "$peer_dir/public.key")
AllowedIPs = $ip_addr/32
__IF_CONF__

	for allowed_ips in "${INTERFACE_ALLOWED_IPS[@]}";do
		cat >> "$peer_if" <<__IF_CONF__
AllowedIPs = $allowed_ips
__IF_CONF__
	done
}

parse_interface_options(){
	local command_name=$1
	shift

	IF_MTU=""

	while [ "$#" -gt 0 ];do
		case "$1" in
		--mtu)
			if [ "$#" -lt 2 ];then
				echo_error "$1 requires a value"
				return 1
			fi
			validate_mtu "$2"
			IF_MTU=$2
			shift 2
		;;
		*)
			echo_error "unknown $command_name option: $1"
			return 1
		;;
		esac
	done
}

parse_peer_options(){
	local command_name=$1
	shift

	PEER_ALLOWED_IPS=()
	INTERFACE_ALLOWED_IPS=()
	PEER_DNS=""
	PEER_MTU=""
	PEER_KEEPALIVE=""

	while [ "$#" -gt 0 ];do
		case "$1" in
		--peer-allowed-ips|--pa|-pa)
			if [ "$#" -lt 2 ];then
				echo_error "$1 requires a value"
				return 1
			fi
			PEER_ALLOWED_IPS+=("$2")
			shift 2
		;;
		--interface-allowed-ips|--ia|-ia)
			if [ "$#" -lt 2 ];then
				echo_error "$1 requires a value"
				return 1
			fi
			INTERFACE_ALLOWED_IPS+=("$2")
			shift 2
		;;
		--dns)
			if [ "$#" -lt 2 ];then
				echo_error "$1 requires a value"
				return 1
			fi
			PEER_DNS=$2
			shift 2
		;;
		--mtu)
			if [ "$#" -lt 2 ];then
				echo_error "$1 requires a value"
				return 1
			fi
			validate_mtu "$2"
			PEER_MTU=$2
			shift 2
		;;
		--keepalive|--ka|-ka)
			if [ "$#" -lt 2 ];then
				echo_error "$1 requires a value"
				return 1
			fi
			validate_keepalive "$2"
			PEER_KEEPALIVE=$2
			shift 2
		;;
		*)
			echo_error "unknown $command_name option: $1"
			return 1
		;;
		esac
	done
}

load_peer_options(){
	local if_name=$1
	local peer_name=$2
	local peer_conf
	local peer_if
	local line

	PEER_ALLOWED_IPS=()
	INTERFACE_ALLOWED_IPS=()
	PEER_DNS=""
	PEER_MTU=""
	PEER_KEEPALIVE=""
	peer_conf=$(peer_file "$if_name" "$peer_name")
	peer_if=$(peer_interface_file "$if_name" "$peer_name")

	PEER_DNS=$(extract_dns "$peer_conf" || true)
	PEER_MTU=$(extract_mtu "$peer_conf" || true)
	PEER_KEEPALIVE=$(extract_keepalive "$peer_conf" || true)
	while IFS= read -r line;do
		PEER_ALLOWED_IPS+=("$line")
	done < <(extract_allowed_ips_after_first "$peer_conf")

	if [ -f "$peer_if" ];then
		while IFS= read -r line;do
			INTERFACE_ALLOWED_IPS+=("$line")
		done < <(extract_allowed_ips_after_first "$peer_if")
	fi
}

cmd_list_interfaces(){
	cd "$WG_SH2_HOME"
	local if_name=""
	local found=0
	for if_name in * ;do
		if [ -f "./$if_name/interface/interface.conf" ];then
			found=1
			echo "$if_name"
		fi
	done
	if [ "$found" -eq 0 ];then
		echo_warn "any interface not found."
	fi
}

cmd_create_interface(){
	if [ "$#" -lt 5 ];then
		echo "Usage: $1 IF_NAME GW_IP_ADDR HOST PORT [options]"
		return 1
	fi
	local if_name=$2
	local ip_addr=$3
	local host=$4
	local port=$5
	local ip_prefix="${ip_addr%.*}"
	local if_dir="$WG_SH2_HOME/$if_name"
	local if2_dir="$if_dir/interface"
	local if_file="$if2_dir/interface.conf"

	validate_name "interface" "$if_name" || return 1
	parse_interface_options "$1" "${@:6}" || return 1

	if [ -e "$if_file" ] || [ -e "$if2_dir/private.key" ] || [ -e "$if2_dir/public.key" ];then
		echo_warn "$if_name already exists, quit."
		return 1
	fi

	cat <<__END_OF_IF__
will create the interface.

IF_FILE         : $if_file
PRIVATE_KEY     : $if2_dir/private.key
PUBLIC_KEY      : $if2_dir/public.key
IF_NAME         : $if_name
ENDPOINT        : $host:$port
IF_IP_ADDR      : $ip_addr
IP_RANGE        : $ip_prefix.0/24
MTU             : ${IF_MTU:-}
__END_OF_IF__

	if ! confirm_yN ;then
		return 0
	fi

	mkdir -p "$if2_dir"
	create_wg_keys "$if2_dir"
	write_interface_conf "$if_name" "$ip_addr" "$host" "$port" "$IF_MTU"
	cat "$if_file"
}

cmd_update_interface(){
	if [ "$#" -lt 5 ];then
		echo "Usage: $1 IF_NAME GW_IP_ADDR HOST PORT [options]"
		return 1
	fi
	local if_name=$2
	local ip_addr=$3
	local host=$4
	local port=$5
	local if2_dir="$WG_SH2_HOME/$if_name/interface"
	local if_file="$if2_dir/interface.conf"
	local peers_dir="$WG_SH2_HOME/$if_name/peers"
	local peer_path
	local peer_name
	local peer_ip
	local current_endpoint
	local current_ip_addr
	local current_ip_prefix
	local current_mtu

	validate_name "interface" "$if_name" || return 1
	require_interface "$if_name" || return 1
	parse_interface_options "$1" "${@:6}" || return 1
	validate_interface_ip "$if_name" "$ip_addr" || return 1
	current_endpoint=$(conf_value "$if_file" "IF_ENDPOINT")
	current_ip_addr=$(conf_value "$if_file" "IF_IP_ADDR")
	current_ip_prefix=$(conf_value "$if_file" "IF_IP_PREFIX")
	current_mtu=$(extract_mtu "$if_file" || true)

	cat <<__END_OF_IF__
will update the interface.

IF_FILE         : $if_file
IF_NAME         : $if_name

CURRENT:
ENDPOINT        : $current_endpoint
IF_IP_ADDR      : $current_ip_addr
IP_RANGE        : ${current_ip_prefix%.*}.0/24
MTU             : $current_mtu

NEW:
ENDPOINT        : $host:$port
IF_IP_ADDR      : $ip_addr
IP_RANGE        : ${ip_addr%.*}.0/24
MTU             : ${IF_MTU:-}
__END_OF_IF__

	if ! confirm_yN ;then
		return 0
	fi

	write_interface_conf "$if_name" "$ip_addr" "$host" "$port" "$IF_MTU"

	if [ -d "$peers_dir" ];then
		for peer_path in "$peers_dir"/*;do
			if [ ! -f "$peer_path/peer.conf" ];then
				continue
			fi
			peer_name=$(basename "$peer_path")
			peer_ip=$(conf_value "$peer_path/interface.conf" "PEER_IP_ADDR" || true)
			if [ -z "$peer_ip" ];then
				echo_warn "$peer_name has no PEER_IP_ADDR, skipped."
				continue
			fi
			load_peer_options "$if_name" "$peer_name"
			write_peer_confs "$if_name" "$peer_name" "$peer_ip"
		done
	fi

	cat "$if_file"
}

cmd_create_peer(){
	if [ "$#" -lt 4 ];then
		echo "Usage: $1 IF_NAME PEER_NAME IP_ADDR [options]"
		return 1
	fi
	local if_name=$2
	local peer_name=$3
	local ip_addr=$4
	local if_dir="$WG_SH2_HOME/$if_name"
	local if_file="$if_dir/interface/interface.conf"
	local peer_dir="$if_dir/peers/$peer_name"
	local peer_file="$peer_dir/peer.conf"
	local peer_if="$peer_dir/interface.conf"
	local if_endpoint=""
	local default_peer_allowed_ips=""
	local if_ip_prefix=""

	validate_name "interface" "$if_name" || return 1
	validate_name "peer" "$peer_name" || return 1
	require_interface "$if_name" || return 1
	parse_peer_options "$1" "${@:5}" || return 1

	if_ip_prefix=$(conf_value "$if_file" "IF_IP_PREFIX")
	if_endpoint=$(conf_value "$if_file" "IF_ENDPOINT")
	default_peer_allowed_ips="${if_ip_prefix%.*}.0/24"

	validate_peer_ip "$if_name" "$peer_name" "$ip_addr" 0 || return 1

	if [ -e "$peer_dir" ];then
		echo_warn "$peer_name already exists in $if_dir/peers, quit."
		return 1
	fi

	cat <<__END_OF_PEER__
will create the peer.

PEER_DIR        : $peer_dir
PEER_FILE       : $peer_file
PEER_INTERFACE  : $peer_if
PRIVATE_KEY     : $peer_dir/private.key
PUBLIC_KEY      : $peer_dir/public.key
IF_NAME         : $if_name
ENDPOINT        : $if_endpoint
IP_ADDR         : $ip_addr
PEER_ALLOWED_IPS: $default_peer_allowed_ips ${PEER_ALLOWED_IPS[*]:-}
IF_ALLOWED_IPS  : $ip_addr/32 ${INTERFACE_ALLOWED_IPS[*]:-}
MTU             : ${PEER_MTU:-}
KEEPALIVE       : ${PEER_KEEPALIVE:-}
__END_OF_PEER__

	if ! confirm_yN ;then
		return 0
	fi

	mkdir -p "$peer_dir"
	create_wg_keys "$peer_dir"
	write_peer_confs "$if_name" "$peer_name" "$ip_addr"

	echo
	cat "$peer_file"
}

cmd_update_peer(){
	if [ "$#" -lt 4 ];then
		echo "Usage: $1 IF_NAME PEER_NAME IP_ADDR [options]"
		return 1
	fi
	local if_name=$2
	local peer_name=$3
	local ip_addr=$4
	local if_file="$WG_SH2_HOME/$if_name/interface/interface.conf"
	local peer_dir="$WG_SH2_HOME/$if_name/peers/$peer_name"
	local if_endpoint=""
	local default_peer_allowed_ips=""
	local if_ip_prefix=""
	local peer_conf=""
	local peer_if=""
	local current_endpoint=""
	local current_ip_addr=""
	local current_peer_allowed_ips=""
	local current_interface_allowed_ips=""
	local current_dns=""
	local current_mtu=""
	local current_keepalive=""
	local new_peer_allowed_ips=""
	local new_interface_allowed_ips=""

	validate_name "interface" "$if_name" || return 1
	validate_name "peer" "$peer_name" || return 1
	require_interface "$if_name" || return 1
	require_peer "$if_name" "$peer_name" || return 1
	parse_peer_options "$1" "${@:5}" || return 1

	if_ip_prefix=$(conf_value "$if_file" "IF_IP_PREFIX")
	if_endpoint=$(conf_value "$if_file" "IF_ENDPOINT")
	default_peer_allowed_ips="${if_ip_prefix%.*}.0/24"
	peer_conf=$(peer_file "$if_name" "$peer_name")
	peer_if=$(peer_interface_file "$if_name" "$peer_name")
	current_endpoint=$(extract_endpoint "$peer_conf" || true)
	current_ip_addr=$(conf_value "$peer_if" "PEER_IP_ADDR")
	current_peer_allowed_ips=$(extract_allowed_ips "$peer_conf" | join_lines)
	current_interface_allowed_ips=$(extract_allowed_ips "$peer_if" | join_lines)
	current_dns=$(extract_dns "$peer_conf" || true)
	current_mtu=$(extract_mtu "$peer_conf" || true)
	current_keepalive=$(extract_keepalive "$peer_conf" || true)
	new_peer_allowed_ips="$default_peer_allowed_ips"
	if [ "${#PEER_ALLOWED_IPS[@]}" -gt 0 ];then
		new_peer_allowed_ips="$new_peer_allowed_ips ${PEER_ALLOWED_IPS[*]}"
	fi
	new_interface_allowed_ips="$ip_addr/32"
	if [ "${#INTERFACE_ALLOWED_IPS[@]}" -gt 0 ];then
		new_interface_allowed_ips="$new_interface_allowed_ips ${INTERFACE_ALLOWED_IPS[*]}"
	fi

	validate_peer_ip "$if_name" "$peer_name" "$ip_addr" 1 || return 1

	cat <<__END_OF_PEER__
will update the peer.

PEER_DIR        : $peer_dir
PEER_FILE       : $peer_conf
PEER_INTERFACE  : $peer_if
IF_NAME         : $if_name
STATUS          : $(peer_status "$if_name" "$peer_name")

CURRENT:
ENDPOINT        : $current_endpoint
IP_ADDR         : $current_ip_addr
PEER_ALLOWED_IPS: $current_peer_allowed_ips
IF_ALLOWED_IPS  : $current_interface_allowed_ips
DNS             : $current_dns
MTU             : $current_mtu
KEEPALIVE       : $current_keepalive

NEW:
ENDPOINT        : $if_endpoint
IP_ADDR         : $ip_addr
PEER_ALLOWED_IPS: $new_peer_allowed_ips
IF_ALLOWED_IPS  : $new_interface_allowed_ips
DNS             : ${PEER_DNS:-}
MTU             : ${PEER_MTU:-}
KEEPALIVE       : ${PEER_KEEPALIVE:-}
__END_OF_PEER__

	if ! confirm_yN ;then
		return 0
	fi

	write_peer_confs "$if_name" "$peer_name" "$ip_addr"

	echo
	cat "$(peer_file "$if_name" "$peer_name")"
}

cmd_list_peers(){
	if [ -z "${2:-}" ];then
		echo "Usage: $1 IF_NAME"
		return 1
	fi

	local if_name=$2
	local peers_dir="$WG_SH2_HOME/$if_name/peers"
	local peer=""
	local peer_name=""
	local ip_addr=""
	local found=0

	validate_name "interface" "$if_name" || return 1
	if [ ! -d "$WG_SH2_HOME/$if_name" ];then
		echo "interface $if_name not found, quit"
		return 1
	fi

	if [ -d "$peers_dir" ];then
		for peer in "$peers_dir"/* ;do
			if [ -f "$peer/peer.conf" ];then
				found=1
				peer_name=$(basename "$peer")
				ip_addr="-"
				if [ -f "$peer/interface.conf" ];then
					ip_addr=$(conf_value "$peer/interface.conf" "PEER_IP_ADDR" || true)
					ip_addr=${ip_addr:-"-"}
				fi
				printf "%s %s %s\n" "$peer_name" "$ip_addr" "$(peer_status "$if_name" "$peer_name")"
			fi
		done
	fi
	if [ "$found" -eq 0 ];then
		echo_warn "any peers not found in $if_name"
	fi
}

cmd_disable_peer(){
	if [ "$#" -lt 3 ];then
		echo "Usage: $1 IF_NAME PEER_NAME"
		return 1
	fi

	local if_name=$2
	local peer_name=$3
	local disabled_file

	validate_name "interface" "$if_name" || return 1
	validate_name "peer" "$peer_name" || return 1
	require_peer "$if_name" "$peer_name" || return 1
	disabled_file=$(peer_disabled_file "$if_name" "$peer_name")

	if [ -f "$disabled_file" ];then
		echo_warn "$peer_name is already disabled."
		return 0
	fi

	if ! confirm_yN ;then
		return 0
	fi
	: > "$disabled_file"
	echo "$peer_name disabled"
}

cmd_enable_peer(){
	if [ "$#" -lt 3 ];then
		echo "Usage: $1 IF_NAME PEER_NAME"
		return 1
	fi

	local if_name=$2
	local peer_name=$3
	local disabled_file

	validate_name "interface" "$if_name" || return 1
	validate_name "peer" "$peer_name" || return 1
	require_peer "$if_name" "$peer_name" || return 1
	disabled_file=$(peer_disabled_file "$if_name" "$peer_name")

	if [ ! -f "$disabled_file" ];then
		echo_warn "$peer_name is already enabled."
		return 0
	fi

	if ! confirm_yN ;then
		return 0
	fi
	rm -f "$disabled_file"
	echo "$peer_name enabled"
}

cmd_delete_peer(){
	if [ "$#" -lt 3 ];then
		echo "Usage: $1 IF_NAME PEER_NAME"
		return 1
	fi

	local if_name=$2
	local peer_name=$3
	local dir
	local disabled_file

	validate_name "interface" "$if_name" || return 1
	validate_name "peer" "$peer_name" || return 1
	require_peer "$if_name" "$peer_name" || return 1
	dir=$(peer_dir "$if_name" "$peer_name")
	disabled_file=$(peer_disabled_file "$if_name" "$peer_name")

	if [ ! -f "$disabled_file" ];then
		echo_warn "$peer_name is enabled. disable-peer before delete-peer."
		return 1
	fi

	echo "will delete peer: $dir"
	if ! confirm_yN ;then
		return 0
	fi
	rm -rf "$dir"
	echo "$peer_name deleted"
}

cmd_render_interface(){
	if [ -z "${2:-}" ];then
		echo "Usage: $1 IF_NAME"
		return 1
	fi

	local if_name=$2
	local if_file
	local peers_dir="$WG_SH2_HOME/$if_name/peers"
	local peer_if=""
	local peer_name=""
	validate_name "interface" "$if_name" || return 1
	require_interface "$if_name" || return 1
	if_file=$(interface_file "$if_name")

	print_interface_with_include "$if_file" "$(interface_include_file "$if_name")"
	if [ -d "$peers_dir" ];then
		for peer_if in "$peers_dir"/*/interface.conf;do
			if [ ! -f "$peer_if" ];then
				continue
			fi
			peer_name=${peer_if#"$peers_dir/"}
			peer_name=${peer_name%/interface.conf}
			if [ -f "$(peer_disabled_file "$if_name" "$peer_name")" ];then
				continue
			fi
			echo
			cat "$peer_if"
		done
	fi
}

cmd_edit_interface_include(){
	if [ -z "${2:-}" ];then
		echo "Usage: $1 IF_NAME"
		return 1
	fi

	local if_name=$2
	validate_name "interface" "$if_name" || return 1
	require_interface "$if_name" || return 1
	edit_include_file "$(interface_include_file "$if_name")"
}

cmd_show_interface(){
	if [ -z "${2:-}" ];then
		echo "Usage: $1 IF_NAME"
		return 1
	fi

	local if_name=$2
	local if_file
	validate_name "interface" "$if_name" || return 1
	require_interface "$if_name" || return 1
	if_file=$(interface_file "$if_name")
	print_interface_with_include "$if_file" "$(interface_include_file "$if_name")"
}

cmd_show_peer(){
	if [ "$#" -lt 3 ];then
		echo "Usage: $1 IF_NAME PEER_NAME"
		return 1
	fi

	local if_name=$2
	local peer_name=$3
	local file
	validate_name "interface" "$if_name" || return 1
	validate_name "peer" "$peer_name" || return 1
	require_peer "$if_name" "$peer_name" || return 1
	file=$(peer_file "$if_name" "$peer_name")
	print_peer_with_include "$file" "$(peer_include_file "$if_name" "$peer_name")"
}

cmd_edit_peer_include(){
	if [ "$#" -lt 3 ];then
		echo "Usage: $1 IF_NAME PEER_NAME"
		return 1
	fi

	local if_name=$2
	local peer_name=$3
	validate_name "interface" "$if_name" || return 1
	validate_name "peer" "$peer_name" || return 1
	require_peer "$if_name" "$peer_name" || return 1
	edit_include_file "$(peer_include_file "$if_name" "$peer_name")"
}

cmd_show_peer_interface(){
	if [ "$#" -lt 3 ];then
		echo "Usage: $1 IF_NAME PEER_NAME"
		return 1
	fi

	local if_name=$2
	local peer_name=$3
	local file
	validate_name "interface" "$if_name" || return 1
	validate_name "peer" "$peer_name" || return 1
	file=$(peer_interface_file "$if_name" "$peer_name")
	if [ ! -f "$file" ];then
		echo_warn "$file not found, quit."
		return 1
	fi
	cat "$file"
}

cmd_show_peer_qr(){
	if [ "$#" -lt 3 ];then
		echo "Usage: $1 IF_NAME PEER_NAME"
		return 1
	fi

	local if_name=$2
	local peer_name=$3
	local file
	validate_name "interface" "$if_name" || return 1
	validate_name "peer" "$peer_name" || return 1
	require_peer "$if_name" "$peer_name" || return 1
	file=$(peer_file "$if_name" "$peer_name")

	if ! command -v qrencode >/dev/null 2>&1;then
		echo_error "qrencode not found. install qrencode to use show-peer-qr."
		return 1
	fi

	print_peer_with_include "$file" "$(peer_include_file "$if_name" "$peer_name")" | qrencode -t ansiutf8
}

dispatch(){
	case "${1:-}" in
	list-interfaces)
		require_wg_command
		cmd_list_interfaces "$@"
	;;
	create-interface)
		require_wg_command
		cmd_create_interface "$@"
	;;
	update-interface)
		require_wg_command
		cmd_update_interface "$@"
	;;
	create-peer)
		require_wg_command
		cmd_create_peer "$@"
	;;
	update-peer)
		require_wg_command
		cmd_update_peer "$@"
	;;
	edit-interface-include)
		require_wg_command
		cmd_edit_interface_include "$@"
	;;
	edit-peer-include)
		require_wg_command
		cmd_edit_peer_include "$@"
	;;
	list-peers)
		require_wg_command
		cmd_list_peers "$@"
	;;
	disable-peer)
		require_wg_command
		cmd_disable_peer "$@"
	;;
	enable-peer)
		require_wg_command
		cmd_enable_peer "$@"
	;;
	delete-peer)
		require_wg_command
		cmd_delete_peer "$@"
	;;
	render-interface)
		require_wg_command
		cmd_render_interface "$@"
	;;
	show-interface)
		require_wg_command
		cmd_show_interface "$@"
	;;
	show-peer)
		require_wg_command
		cmd_show_peer "$@"
	;;
	show-peer-interface)
		require_wg_command
		cmd_show_peer_interface "$@"
	;;
	show-peer-qr)
		require_wg_command
		cmd_show_peer_qr "$@"
	;;
	help|-h|--help)
		usage
	;;
	exit|quit)
		return 2
	;;
	"")
		usage
	;;
	*)
		echo_warn "unknown command: $1"
		usage
		return 1
	;;
	esac
}

run_repl(){
	WG_SH2_INTERACTIVE=1
	local wg_sh2_prompt
	local -a cmd_line
	wg_sh2_prompt="$(basename "$0"):$WG_SH2_HOME/> "

	while true;do
		if ! read -e -r -a cmd_line -p "$wg_sh2_prompt";then
			echo
			break
		fi
		if [ "${#cmd_line[@]}" -gt 0 ];then
			history -s "${cmd_line[@]}"
		fi
		if dispatch "${cmd_line[@]}";then
			:
		else
			local status=$?
			if [ "$status" -eq 2 ];then
				break
			fi
		fi
	done
}

if [ "$#" -gt 0 ];then
	dispatch "$@"
else
	run_repl
fi
