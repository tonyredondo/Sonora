# ReplayGain analysis: native screens

Captured from Sonora on iPhone 17 Simulator / iOS 27, 2026-10-16. The files and music are synthetic QA fixtures. These are native app captures; the [analysis guide](../../replaygain-analysis.md) describes the behavior and validation limits. [captures.json](captures.json) records source tests and image hashes.

| Noche: completed song result | Papel: saved result after relaunch |
| --- | --- |
| <img src="result-noche.png" width="300" alt="Noche showing a song's measured ReplayGain and peak" /> | <img src="restored-papel.png" width="300" alt="Papel showing the same saved result after restarting Sonora" /> |

| Explicit file-tag save | Multiple songs, including a subfolder |
| --- | --- |
| <img src="tags-saved-noche.png" width="300" alt="One of one compatible files saved after confirmation" /> | <img src="selection-noche.png" width="300" alt="Three selected songs with reused local measurements" /> |

The album action was also exercised at the largest accessibility text size. The form scrolls so the text and controls retain their size.

<img src="album-papel-largest.png" width="300" alt="Shared album gain in Papel at the largest accessibility text size" />
