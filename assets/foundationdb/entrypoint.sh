#!/bin/bash
# One fdbserver process per node.
#
# FDB_PUBLIC_IP is set by the orchestrator to a statically allocated address,
# because podman reassigns addresses on restart and a coordinator list records
# them. Auto-detection is only a fallback for running the image by hand.
set -euo pipefail

: "${FDB_PORT:=4500}"
: "${FDB_CLUSTER_FILE:=/var/fdb/fdb.cluster}"
: "${FDB_DATA_DIR:=/var/fdb/data}"
: "${FDB_LOG_DIR:=/var/fdb/logs}"
: "${FDB_CLUSTER_DESCRIPTION:=rivet}"
: "${FDB_CLUSTER_ID:=rivet}"
: "${FDB_CLASS:=unset}"

detect_ip() {
	if [ -n "${FDB_PUBLIC_IP:-}" ]; then
		echo "${FDB_PUBLIC_IP}"
	else
		hostname -i | awk '{print $1}'
	fi
}

public_ip="$(detect_ip)"
if [ -z "${public_ip}" ]; then
	echo "could not determine this node's address; set FDB_PUBLIC_IP" >&2
	exit 1
fi

# FoundationDB cluster files require IPv6 addresses to be bracketed.
case "${public_ip}" in
	*:*)
		public_address="[${public_ip}]:${FDB_PORT}"
		listen_address="[::]:${FDB_PORT}"
		;;
	*)
		public_address="${public_ip}:${FDB_PORT}"
		listen_address="0.0.0.0:${FDB_PORT}"
		;;
esac

mkdir -p "${FDB_DATA_DIR}" "${FDB_LOG_DIR}" "$(dirname "${FDB_CLUSTER_FILE}")"

# Coordinator addresses are not knowable before the nodes exist, so a node with
# no FDB_COORDINATORS bootstraps as its own sole coordinator. The orchestrator
# reads the addresses back and rewrites this file with the shared set.
: "${FDB_COORDINATORS:=${public_address}}"

# fdbserver rewrites the cluster file when coordinators change, so only seed it
# when it is missing. Otherwise a restart would clobber a live coordinator set.
if [ ! -s "${FDB_CLUSTER_FILE}" ]; then
	echo "${FDB_CLUSTER_DESCRIPTION}:${FDB_CLUSTER_ID}@${FDB_COORDINATORS}" > "${FDB_CLUSTER_FILE}"
fi

echo "starting fdbserver on ${public_address} (class=${FDB_CLASS})" >&2
cat "${FDB_CLUSTER_FILE}" >&2

exec fdbserver \
	--cluster-file "${FDB_CLUSTER_FILE}" \
	--datadir "${FDB_DATA_DIR}" \
	--logdir "${FDB_LOG_DIR}" \
	--public-address "${public_address}" \
	--listen-address "${listen_address}" \
	--class "${FDB_CLASS}"
