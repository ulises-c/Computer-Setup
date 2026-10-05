# Homepage generation and compact Servers inventory

The game host's opt-in grouped bar shows Compute, Storage, Connectivity and
System. Lighting is deliberately separate on the **OpenRGB** card, never
in `topbarExtras`; `topbar.rgb` is rejected by the generator. The card maps
the installed RGB exporter's flat `rows` array and shows its update age.
See [the game dashboard guide](../../linux-game-server/homepage/README.md)
and [the keep-off service guide](../../linux-game-server/rgb/README.md).

## Servers inventory

Every dashboard gets the same six-row Servers cards from `fleet.json`:
Platform, Board / SoC, CPU (model + cores / threads), Memory (OS-visible usable
GiB), Graphics (model / type / dedicated VRAM or shared / unknown), and Software
(OS + kernel grouped). Hostname is not repeated as another row.

Platform, board/chipset, CPU and graphics are the user-approved live inventory
snapshot in each server's `facts` object. Update those fields after hardware
changes, rather than guessing from a vendor or OS. The HP game machine identifies
as OMEN **25L GT12** in platform inventory; its OpenRGB controller calls itself
**HP Omen 30L**. They are separate identification sources, not interchangeable.
Pi GPU capacity is unavailable; main Intel graphics share RAM; only the game
GTX 1070 has confirmed 8 GiB dedicated memory.

Memory stays `/api/4/mem.total`, scaled by `1/1073741824` with Homepage native
`float` formatting and the explicit **GiB usable** suffix. It is not installed
DIMM capacity and is not a nominal 16 / 4 / 32 GB label. Software stays the live
`/api/4/system` `linux_distro` plus `os_version`. The native customapi widgets
refresh hourly; there is no new card JS renderer, polling loop or endpoint.
`remap: [{any: true, to: ...}]` renders recorded hardware facts natively;
`additionalField` groups OS and kernel into one row. All rows use list layout.

The generator writes all three hosts' `services.yaml`. Card changes do not
enable the grouped topbar on main/Pi. During a card-only rollout, transfer only
the Servers block after checking the rest of each destination config. Preserve
the host's private `.env`, other service groups and topbar artifacts. Revalidate
with the **actual container PORT** (main/game 3000; Pi 3001), then reload and
verify the rendered rows. Synchronizing the entire branch would also update the
shared Glances entrypoint and require its new telemetry bind mount; do not do
that under a Servers-only authorization.

```sh
python3 server-base/homepage/generate.py
python3 server-base/homepage/generate.py --check
python3 server-base/tests/test_generate.py -v
```
