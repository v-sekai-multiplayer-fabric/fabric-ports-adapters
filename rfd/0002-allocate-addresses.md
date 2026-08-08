# RFD 0002 — Allocate node addresses, do not discover them

## Status

Accepted, implemented, verified against a live cluster.

## Problem

FoundationDB records coordinators by IP address. A cluster cannot form until
those addresses are known, and the addresses do not exist until the nodes do.

The obvious sequence follows from that circularity:

1. create the nodes
2. read their addresses back
3. rewrite each node's cluster file with the shared coordinator set
4. restart so the new file takes effect
5. `configure new`

Every step of that fails under podman, and all of the failures are quiet.

## Three failures, in the order they were found

### 1. A node with no coordinators names itself

A node started without `FDB_COORDINATORS` writes a cluster file naming only
itself. Three such nodes are three independent one-node clusters.

Each one logs:

```
FDBD joined cluster.
```

So all three look healthy. `configure new` then succeeds against exactly one of
them and silently orphans the rest.

### 2. Rewriting the cluster file does not take effect

`fdbserver` reads the cluster file once, at startup. The natural fix is to
signal it to restart from inside the container:

```sh
podman exec <node> sh -c 'kill 1'
```

This silently does nothing. The kernel discards unhandled signals sent to PID 1
from inside its own PID namespace. Observed as a node whose file on disk was
correct while its log still showed the old self-only set:

```
starting fdbserver on 10.89.0.2:4500
rivet:rivet@10.89.0.2:4500        <- self-only, but disk already had the merged set
```

The restart has to come from the substrate, not from inside the node.

### 3. Restarting works, and then invalidates the addresses

Restarting through systemd does apply the new file. Podman then assigns the
container a **new address**, so the restart that applies a coordinator list is
the same act that makes the list wrong:

| | coordinator list | actual IP after restart |
|---|---|---|
| node1 | `10.89.0.5` | `10.89.0.8` |
| node2 | `10.89.0.6` | `10.89.0.9` |
| node3 | `10.89.0.7` | `10.89.0.10` |

The sequence is circular and cannot be fixed by reordering it.

## Decision

Allocate addresses up front instead of discovering them.

`Spec.fdb_plan/1` assigns node N a static address on a dedicated subnet
(`10.89.100.0/24`, node N at `10.89.100.{10+N}`). The podman network is created
with that subnet, and each `.container` unit pins its address:

```
Network=rivet-fabric:ip=10.89.100.11
```

The coordinator set is therefore computable before anything exists, and is
passed to every node at creation via `FDB_COORDINATORS`. No node ever runs with
a self-only cluster file, and no restart is required.

## Consequences

All three failures disappear at once, and the implementation gets smaller: the
discovery loop, the forced-rewrite step, and the restart step are all gone. The
test suite dropped from 15s to under 0.1s because the sleeps went with them.

The cluster also survives a restart, which the previous designs did not:

```
$ systemctl --user restart mf-rivet-fdb--mf-rivet-fdb-1.service
$ podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' mf-rivet-fdb--mf-rivet-fdb-1
10.89.100.11                       <- unchanged, still in the coordinator set
$ fdbcli --exec 'status minimal'
The database is available
```

`Bootstrap.verify_agreement/3` is retained even though the failure it guards
against should now be impossible. It is cheap, and it is the only check that
distinguishes "three nodes in one cluster" from "three one-node clusters that
each look healthy".

The cost is that the subnet is now owned by this tool and must not collide with
podman's default `10.89.0.0/24` pool, which is why a separate subnet is used.

## Verified

A live 3-node cluster: `double` redundancy, 3 coordinators, fault tolerance of
1 machine, database available, addresses stable across `systemctl restart`.
