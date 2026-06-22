# Benchmarking NAS throughput

Three different things get called "speed", and they answer different questions:

| Tool | What it measures |
|------|------------------|
| speedtest-tracker | **WAN** — your ISP download/upload. Nothing to do with the LAN. |
| OpenSpeedTest (`:3030`) | **LAN network** — a client device's browser → server bandwidth. |
| The `dd` procedure below | **Real-world NAS** — the whole chain: network + USB enclosure + disk. |

The `dd` test is the number you actually feel when copying files to a share. Run
it in two stages so a slow result points at the right culprit.

## Stage A — disk baseline (on the server)

Rules out the network and shows the drive's raw ceiling. `oflag=direct` bypasses
the page cache so you measure the disk, not RAM.

```sh
# write ~2 GB straight to the 14TB drive
dd if=/dev/zero of=/mnt/wd14tb/bench.tmp bs=1M count=2048 oflag=direct status=progress

# drop caches, then read it back
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
dd if=/mnt/wd14tb/bench.tmp of=/dev/null bs=1M status=progress

rm /mnt/wd14tb/bench.tmp
```

Swap the path for `/mnt/seagate4tb` or `/mnt/wd1tb` to test the other bays. The
1 TB drive is nearly empty, so it's the safest scratch target.

## Stage B — over Samba (from a client)

The throughput you actually experience. Mount the share, then:

```sh
# macOS client (share mounted at /Volumes/wd14tb)
dd if=/dev/zero of=/Volumes/wd14tb/bench.tmp bs=1m count=2048   # write
dd if=/Volumes/wd14tb/bench.tmp of=/dev/null bs=1m             # read
rm /Volumes/wd14tb/bench.tmp
```

On a Linux client use `bs=1M`. For a live MB/s readout with a real file instead:
`rsync -h --progress <bigfile> /mount/`.

## Reading the results

- Gigabit LAN tops out around **110–118 MB/s** effective. If Stage B hits that
  but Stage A is much higher, you're **network-bound** — expected on gigabit, and
  OpenSpeedTest will confirm it.
- If Stage B is well below Stage A *and* below ~110 MB/s, the bottleneck is **SMB
  tuning or the USB enclosure**, not the wire.
- Check the link ceiling itself with `ethtool eno2 | grep Speed`. If it reports
  2.5GbE+ and OpenSpeedTest still caps low, the docker-proxy port mapping is the
  limit — switch OpenSpeedTest to host networking (see its `docker-compose.yml`).
