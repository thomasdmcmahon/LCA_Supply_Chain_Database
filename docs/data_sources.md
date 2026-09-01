# Data soruces

Two independet sources feed the project: the inventory data (ELCD 3.2) and the characterization factors used to turn inventory into impact scores. They have different origians and are documented separately.

### ELCD 3.2 (inventory data)

- Source: openLCA Nexus: https://nexus.openlca.org/database/ELCD
- Originator: European Commission, Joint Research Center (JRC)
- Dataset selected: ELCD 3.2
- Original format downloaded: openLCA `.zolca`
- Access date: 2026-05-18

**Paths**:
Original archive: data/raw/elcd_3_2/original_download/
Exported parser input: data/raw/elcd_3_2/exported/
Preferred parser input: data/raw/elcd_3_2/exported/ilcd/
Optional parser input: data/raw/elcd_3_2/exported/jsonld/
Makefile ILCD_DIR: data/raw/elcd_3_2/exported/ilcd/ILCD

Note: Raw an processed dataset files are gitignored and not committed. Download the source data from Nexus. The download is an openLCA archive, not loose ILCD XML. The ILCD exported produced from it by openLCA is what the Python pipeline reads.

## Characterization factors

Impact scores are inventory amounts multiplied by a factor per substance, so the results are only as good as the factors. Only sourced factors are used here; categories without one are left empty.

- Acidification, Accumulated Exceedance (molc/kg):
  EC-JRC (2012), _Characterisation factors of the ILCD Recommended LCIA
  methods_.
  https://eplca.jrc.ec.europa.eu/uploads/LCIA-characterization-factors-of-the-ILCD.pdf
- Not characterized: nitrate eutrophication, cumulative energy demand.
