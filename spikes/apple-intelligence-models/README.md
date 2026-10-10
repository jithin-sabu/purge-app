# Spike: remove the Apple Intelligence models, and download them again later

Standalone command-line tool for [purge-app#133](https://github.com/jithin-sabu/purge-app/issues/133).
It is **not part of Purge** and nothing in it ships. Its job is to find out, on
real Macs, whether the approach in the issue holds up before any of it is built
into the app. The issue is explicit that this needs a yes before it lands:
these would be Purge's first private Apple APIs and its first persistent change
to the system.

## What it does

| Command | What happens |
|---|---|
| `aimodels status` | Which model sets are on disk and how big, which accounts use Apple Intelligence, whether the download block is installed, free space. Public file reads only. |
| `aimodels measure --dump` | Reads MobileAsset's per-model records and prints them raw, so the record layout and the size keys can be confirmed on each macOS. |
| `aimodels check` | Read-only preflight: does this macOS still map each asset set to the asset type the catalog expects, is the asset service reachable, and does CacheDelete honour the service filter. Nothing is removed. |
| `aimodels remove` | Shows the plan and asks. Then: install the download-block profile (macOS 27), release the models, purge through CacheDelete limited to the MobileAsset service, measure the volume's free space before and after. |
| `aimodels restore` | Remove the profile, then ask the asset service to download the sets again (macOS 27) or open Apple's switch (macOS 15 and 26). |
| `aimodels snapshot --note "…"` | Record free space and the records to the journal, for the readings after a restart and after a day online. |
| `aimodels selftest` | Checks on the logic that must not go wrong, touching nothing. CI runs this. |

Every private call runs in a throwaway child process (`aimodels __worker <op>`),
so a changed signature crashes that child and is reported as a crash, not a
hang or a crash of the tool.

## Build

Xcode 16 or later, on macOS 14 or later.

```sh
cd spikes/apple-intelligence-models
swift build -c release
.build/release/aimodels selftest
.build/release/aimodels status
```

## The three steps, and where each one comes from

| Step | How | Source |
|---|---|---|
| Measure | Sum the per-asset records under `/System/Library/AssetsV2/persisted/AutoAssetDescriptors`, with lock entries from its `AutoAssetLocker` folder. World-readable; no private API. | The issue. The key names are **not documented anywhere**; `measure --dump` exists to learn them. |
| Release (macOS 27) | `ResetAssetSets` over XPC to `com.apple.siri.uaf.subscription.service`, one set per request. `AssetSets` is checked non-empty in the bridge before a connection is even made. | pared, RemoveMacAI |
| Release (macOS 15, 26) | Open Apple Intelligence & Siri; the user turns it off. | The issue |
| Free the space now | `CacheDeletePurgeSpaceWithInfo` with `CACHE_DELETE_SERVICES` set to the MobileAsset service. Sent only after a read-only `CacheDeleteCopyPurgeableSpaceWithInfo` with and without the filter shows the filter at work. | Request keys from DeviceLink's `_DLPurgeDiskSpaceOnComputer` (via BrainLayer and pymobiledevice3). The services key is from a Mail cache-delete plist, not from a purge request: **unverified**. |
| Keep them gone (macOS 27) | A profile forcing `com.apple.MobileAsset` `DownloadServerBaseURLOverride-<assetType>` to `https://127.0.0.1:9/purge-blocked/`, approved once by the user. | pared, RemoveMacAI |
| Download again | Remove the profile, then `Unsubscribe` and `Subscribe` the sets with the usage aliases from pared's catalog. On 15 and 26, the user turns the switch on. | pared |

The order in `remove` is block first, then release, then purge: the block has
to be in place before the models are released, or macOS can start downloading
them again in the gap.

## Safety rules the tool enforces

- `AssetSets` is never empty. Refused in the Objective-C bridge and again in the worker.
- The purge never runs unfiltered. The worker refuses a purge request without
  `CACHE_DELETE_SERVICES`, and `remove` sends one only when the filtered
  purgeable figure is lower than the unfiltered one and the filtered reply
  names no other service. Any other outcome prints both raw replies and skips
  the purge.
- Private calls run in a child process.
- Other accounts that use Apple Intelligence are named before anything is removed.
- Space freed is the volume's free space before versus after, settled over
  consecutive readings, with Purge's 64 MB noise floor. Apple's figures are
  shown as what they are: the records' sizes.
- Nothing here is scheduled or automatic; every change asks first.

## Test plan (from the issue)

Run on macOS 27, and if possible 15 and 26. Keep the journal
(`~/Library/Application Support/Purge/spikes/apple-intelligence-models.json`)
and paste the table into the issue.

1. `aimodels measure --dump --all > records.txt`: do the records exist, what
   are the size keys, do installed and released records look different?
2. `aimodels check`: does the asset service match the catalog, and is the
   CacheDelete filter honoured? If the purgeable query gives no reply, try
   `--call-style block`. If the service id is not defined, the check lists the
   ones that mention MobileAsset; pass the right one with `--service`.
3. `aimodels remove`: record free space before and after.
4. Restart, then `aimodels snapshot --note "after restart"`.
5. After a day online: `aimodels snapshot --note "after a day"`. Did anything come back?
6. `aimodels restore`, wait for the downloads, then `aimodels snapshot --note "after download again"`.

| Reading | macOS 27 | macOS 26 | macOS 15 |
|---|---|---|---|
| Records found, size key | | | |
| Service filter honoured | | | |
| Free before → after `remove` | | | |
| After restart | | | |
| After a day online | | | |
| After `restore` | | | |

## Open questions the spike has to settle

- **Record layout.** The descriptor and lock file names are confirmed from a
  trace (`AutoAssetDescriptors/AutoAssetLocker/AutoAssetLocker_Entry_<type>_<specifier>_<version>_0.state`),
  but not the record contents. `measure` searches for the likely size keys
  (`_UnarchivedSize`, `_MeasuredSize`, `_CompressedSize`, …) and falls back to
  the largest number under any key naming a size, and says which key it used.
  If the records are not property lists, it says so and `--dump` shows the bytes.
- **CacheDelete call shape.** Two call styles are implemented because neither
  is documented: synchronous returning a dictionary, or a reply block. The
  default is `sync`; `check` suggests the other when the first gives no reply.
  Which one `deleted` accepts, and which urgency level reaches the MobileAsset
  service, are things to record.
- **Service filter.** Whether `CACHE_DELETE_SERVICES` restricts a purge at all,
  and what the service's id really is. The purge is refused until the
  read-only comparison says yes.
- **macOS 27 master switch.** Still from press reports only.
- **macOS 15 and 26.** Whether the records and the CacheDelete calls look the
  same there. `measure` and `check` run on every version; only `remove`'s
  release step differs.
- **Profile across updates.** Whether the download block survives a macOS update.
- **Which sets.** The catalog removes five sets. `status` and the `remove` plan
  list what each one switches off, from pared's consumer map.

## References

- pared: [how-it-works.md](https://github.com/4evy/pared/blob/master/docs/how-it-works.md),
  [catalog.json](https://github.com/4evy/pared/blob/master/Sources/Pared/Resources/catalog.json),
  `Sources/AssetBridge` (MIT)
- RemoveMacAI: [README](https://github.com/omlahore/RemoveMacAI),
  [UAF.m](https://github.com/omlahore/RemoveMacAI/blob/main/Sources/UAF/UAF.m),
  [Profile.swift](https://github.com/omlahore/RemoveMacAI/blob/main/Sources/removemacai/Profile.swift) (MIT)
- BrainLayer's CacheDelete helper: [cachedelete_purge.swift](https://github.com/EtanHey/brainlayer/blob/main/src/brainlayer/cachedelete_purge.swift)
