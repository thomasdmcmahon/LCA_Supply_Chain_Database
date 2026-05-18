# Data Sources

## ELCD 3.2

- Source: openLCA Nexus
- Dataset selected: ELCD 3.2
- Original format downloaded: openLCA `.zolca`
- Local archive filename: `elcd_3_2_greendelta_v2_18_correction_20220908.zolca`
- Original archive location: `data/raw/elcd_3_2/original_download/`
- Exported parser input location: `data/raw/elcd_3_2/exported/`
- Preferred parser input: `data/raw/elcd_3_2/exported/ilcd/`
- Optional parser input: `data/raw/elcd_3_2/exported/jsonld/`
- Access date: 2026-05-18
- Notes:
  - Raw and processed dataset files are gitignored and not committed.
  - The currently downloaded source is an openLCA archive, not loose ILCD XML files.
  - The Python pipeline uses the ILCD export from openLCA as its main input.
  - The current pipeline has been tested through inspect, parse, transform, and PostgreSQL load steps.
