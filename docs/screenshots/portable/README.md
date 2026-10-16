# CUE, playlists and local copies: native screens

Captured from Sonora on iPhone 17 Simulator / iOS 27, 2026-10-16, using synthetic QA music. These are native app captures. The [feature guide](../../portable-library.md) describes supported formats and validation limits; [captures.json](captures.json) records tests, artifact hashes and source provenance.

The final signed Simulator run passed 93 app/audio tests and four UI tests, with no skipped tests, failures or changed source inputs. The Core suite separately passed 23 tests. CarPlay has native template and transport tests, but its external Simulator display remained black; no CarPlay screenshot or visual head-unit validation is claimed.

| CUE restored paused in Noche | CUE in Papel at maximum text size |
| --- | --- |
| <img src="cue-restored-noche.png" width="300" alt="An eight-second CUE song restored in pause with its title and artist" /> | <img src="cue-player-papel-largest.png" width="300" alt="The same CUE song with large accessible text and player controls visible without scrolling" /> |

| M3U8 imported from Files | Ordered playlist with individual CUE songs |
| --- | --- |
| <img src="playlist-import-noche.png" width="300" alt="Three songs imported from Ruta.m3u8" /> | <img src="playlist-cue-order-noche.png" width="300" alt="Last CUE song, loose audio file and first CUE song in playlist order" /> |

| M3U8 export completed | Local copy queue after normal relaunch |
| --- | --- |
| <img src="playlist-export-noche.png" width="300" alt="A numbered M3U8 export saved without replacing the existing playlist" /> | <img src="local-queue-papel.png" width="300" alt="The Local source restored with three songs, including two separate CUE entries" /> |

The local-import form supports maximum accessibility text and scrolls to its copy records and actions. Original files are preserved. The fixed player above remains on one screen.

<img src="local-copy-papel-largest.png" width="300" alt="The local-folder import explanation in Papel at maximum text size" />
