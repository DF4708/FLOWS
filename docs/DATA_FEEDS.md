<!--
  Copyright (c) 2026 David B. Foster. All rights reserved.
  Contact: wizeman555@gmail.com
  Unauthorized copying, distribution, modification, or use of this file, in
  whole or in part, is strictly prohibited without the express written
  permission of the copyright holder.
-->

# FLOWS data feeds — the primary-source catalog

The "Weather.com charges but gets NOAA's data free" principle, applied to every
category FLOWS presents. Most government and regulator data is *mandated* to be
public; the paid apps just wrap it. This document is the audited map of what we
pull today, what we newly wired, what needs a free key, and what genuinely has
no free primary source.

**Ground rule:** every endpoint below was probed live (a real HTTP request with
its payload inspected) before being listed. Status reflects an actual response,
not a guess. Where a probe failed, the *reason* is recorded — a non-200 is
diagnosed, never assumed broken.

---

## 1. Live sources wired today (keyless unless noted)

| Category | Provider | Host | Key | File |
|---|---|---|---|---|
| Weather forecast (US) | NWS | `api.weather.gov` | — | `NWSForecastService.swift` |
| Weather alerts (US) | NWS CAP | `api.weather.gov` | — | `WeatherAlertService.swift` |
| Weather + alerts (CA) | ECCC | `api.weather.gc.ca` | — | `NWSForecastService.swift`, `WeatherAlertService.swift` |
| Weather (MX) | SMN/CONAGUA | `smn.conagua.gob.mx` | — | `NWSForecastService.swift` |
| Fire hotspots | NOAA HMS | `satepsanone.nesdis.noaa.gov` | — | `LiveHazardFeeds.swift` |
| **Fire perimeters** | NIFC/WFIGS | `services3.arcgis.com/T4QMspbfLg3qTGWY` | — | `LiveHazardFeeds.swift` |
| Earthquakes | USGS | `earthquake.usgs.gov` | — | `LiveHazardFeeds.swift` |
| Air quality | Open-Meteo | `air-quality-api.open-meteo.com` | — | `LiveHazardFeeds.swift` |
| UV index | Open-Meteo | `api.open-meteo.com` | — | `LiveHazardFeeds.swift` |
| **Space weather** | NOAA SWPC | `services.swpc.noaa.gov` | — | `LiveHazardFeeds.swift` |
| **River flood gauges** | NWS/NWPS | `api.water.noaa.gov` | — | `LiveHazardFeeds.swift` |
| Speed limits / bridges | OpenStreetMap | `overpass-api.de` (+2 mirrors) | — | `LiveHazardFeeds.swift`, `RouteAttributes.swift`, `RiskAdvice.swift` |
| River / lake proximity | USGS NHD | `hydro.nationalmap.gov` | — | `LiveHazardFeeds.swift` |
| Elevation / grade | USGS EPQS | `epqs.nationalmap.gov` | — | `RouteAttributes.swift` |
| Flood zones (regulatory) | FEMA NFHL | `hazards.fema.gov` | — | `RouteAttributes.swift` |
| ZIP boundaries | US Census | `tigerweb.geo.census.gov` | — | `ZipBordersAndTransit.swift` |
| Fuel prices (MX) | CRE | `publicacionexterna.azurewebsites.net` | — | `PrimarySources.swift` |
| Work zones | US DOT WZDx | `data.transportation.gov` | — | `PrimarySources.swift` |
| Vehicle economy DB | EPA | `fueleconomy.gov` | — | `EPAVehicleDatabase.swift` |
| NOAA weather radio | WeatherUSA relays | `weatherusa.net` | — | `TruckerRadio.swift` |
| AM/FM stations (US) | radio-browser.info (community) | `all.api.radio-browser.info` → runtime-picked mirror | — | `RadioBrowser.swift` |
| Spotify remote control | Spotify Web API | `api.spotify.com` | user token (optional) | `SpotifyRemote.swift` |
| POI discovery | Apple MapKit | (entitlement) | — | `POIService.swift` |
| Amtrak stations (bundled) | Amtrak GTFS stops.txt, rail-served only | `content.amtrak.com` (bundled snapshot retrieved 2026-07-30, ships as `amtrak_stations.json`; no build-time fetch) | — | `AmtrakStations.swift` |
| Fuel prices (US) | TomTom | `api.tomtom.com` | TomTom | `ZipBordersAndTransit.swift` |
| Ratings / hours / $ | Yelp Fusion | `api.yelp.com` | Yelp | `RatingsAndCost.swift` |
| Vehicle telemetry | Smartcar | `api.smartcar.com` | Smartcar OAuth | `SmartcarLink.swift` |

Rows in **bold** were added in this pass.

---

## 2. Added this pass — keyless primary hazard feeds

All three fill or upgrade an existing risk *family*, blended in
`ContentView.refreshViewportHazards` (the family choropleth path), scored by
pure functions in `HazardFeedScores` and pinned by `PrimaryHazardFeedTests`.

### NOAA SWPC space weather → `radiation` family
`services.swpc.noaa.gov/products/noaa-scales.json` — one small JSON with the
current NOAA scales: **R** (radio blackout), **S** (solar radiation storm), and
**G** (geomagnetic storm), each 0–5. Until now the radiation family had only
Open-Meteo UV (sunburn-through-glass); it now also carries the actual
geophysical signal. The S-scale applies everywhere; the G-scale is
latitude-weighted (its GPS/aurora effects concentrate toward the poles). Quiet
space weather (the norm) contributes nothing, so the map doesn't light up on a
calm day.

### NIFC/WFIGS active perimeters → `fire` family
`WFIGS_Interagency_Perimeters` FeatureServer, queried by viewport envelope as
GeoJSON. Fire was satellite *hotspots* only (a point downwind of smoke). Now the
score also knows whether you are **inside or within 12 km of a mapped active
fire perimeter** (point-in-polygon + buffer). Fire family = worse of the two.

### NWS/NWPS river gauges → `qpf_flood` family
`api.water.noaa.gov/nwps/v1/gauges?bbox…&srid=EPSG_4326` — every river gauge in
the viewport with its **observed flood category** (`action`/`minor`/`moderate`/
`major`). Flood was precipitation *probability*; it now also reflects rivers
that are *actually at flood stage right now*. Flood family = worse of the two.

---

## 3. Free, real, but need a (free) API key — next up

| Feed | Fills / improves | Note |
|---|---|---|
| **EIA petroleum** | Replaces US state-average fuel *estimates* (`FuelPrices.swift`) with government-measured weekly regional prices | Free key; regional, not per-station |
| **AirNow (EPA)** | Official US AQI vs. the modeled Open-Meteo value | Free key |
| **OpenAQ v3** | Global ground-station air quality | Free key |
| **NREL AFDC** | US EV / alt-fuel stations (feeds the EV charging-gap warning) | Free key; `DEMO_KEY` works for testing |
| **OpenChargeMap** | Global EV chargers, community-open | Free key |
| **State 511 systems** | Incidents, closures, DMS, traffic cameras | Most need a free key; **Ontario 511 is open** and was verified |

Because these need credentials, they follow the local-only key pattern
(`defaults write` into the app container, never the repo), same as TomTom/Yelp/
Smartcar. A future proxy server is the path to shipping them across
distributions.

---

## 4. Real feeds worth a deeper integration

- **Mobility Database GTFS catalog** (verified) + **GTFS-Realtime** (MBTA `.pb`
  verified) + **Amtrak GTFS** (verified) — the foundation for real in-app
  transit routing, replacing today's estimated transit ETAs and fares
  (`Mobility.swift`). This is the standing transit-build roadmap item.
- **NOAA MRMS** radar mosaic (verified) — the government radar source to
  wire IF animated radar is wanted back (RainViewer was removed, see §11).
- **NHC** tropical storms and **Avalanche.org** — now **shipped** as the
  `tropical` and `avalanche` families (see §2b), no longer deferred.
- **Blitzortung** lightning (verified) — convective enrichment; needs websocket
  infrastructure, so deferred.

---

## 5. Diagnosed errors — what actually happened (not "broken")

Every non-200 or empty result from the sweep was chased down:

- **FHWA National Bridge Inventory (`geo.dot.gov`)** returned HTTP **200 with a
  JSON error body** `{code: 499, "Token Required"}` (62 bytes). The hosted DOT
  FeatureServer is **token-gated**, so it is *not* a keyless live API. The real
  keyless path is the **annual NBI bulk download** (ASCII/CSV) from FHWA — a
  data refresh, not a live query. OSM `maxheight` (already wired) stays the live
  clearance source.
- **HIFLD rest-area / weigh-station / hospital layers** — my guessed Esri
  service names returned `{"error": "Invalid URL"}` (again HTTP 200 wrapping an
  error). I do **not** have the correct public endpoints, and these POIs are
  already covered by MapKit + OSM in the app, so no regression — just no upgrade
  yet. Correct HIFLD Open Data endpoints are a follow-up.
- **Open-Meteo pollen** returns `null` for all US coordinates: its pollen model
  is **Europe-only**. Shipping it would have shown a blank feature everywhere in
  North America. Dropped — no free NA pollen primary exists (pollen.com / Ambee
  are paid).
- **NWPS bbox** first returned `{"gauges": []}` because the spatial query
  **requires `srid=EPSG_4326`**; with it, 337 gauges returned. Fixed and wired.
- **NREL AFDC** returned `curl: (6) Could not resolve host` — a **DNS failure in
  this build sandbox**, not a broken endpoint (and it needs a key regardless).
- **AirNow / OpenAQ** returned `401` — expected: they need a free key, they are
  not down.

---

## 6. Honest "no free primary" list

- **US per-station fuel prices** — no government feed (unlike Mexico's CRE).
  GasBuddy/OPIS are licensed. TomTom's free tier (wired) is the pragmatic path;
  EIA (free key) covers regional averages.
- **Hotel nightly rates** — proprietary to chains/OTAs. No free primary; the
  ranking uses a labeled neutral reference, never a fabricated price.
- **Toll *costs*** — OSM `toll=yes` says *whether* a road is tolled, not the
  price. Actual toll pricing is paid-only.
- **Real-time truck-parking *availability*** — TPIMS is real but fragmented
  across per-state / MAASTO-regional endpoints, not one clean feed. HIFLD would
  give locations, not live open-space counts.
- **US pollen** — see §5.

> **Note — RainViewer:** removed (see §11).

---

## 2b. Added — four new acute risk families (from sweep 2)

Extending the family taxonomy with hazards a single-country weather feed can't
express. Each is scored by a pure function in `HazardFeedScores`, fetched/cached
in `LiveHazardFeedFetcher`, weighted in `RiskEquations.familyWeights`, labelled
in `RiskFieldService.familyDisplayNames` + `HazardStyle`, and given band-scaled
expert advice in `RiskAdvice`. All pinned by `AcuteFamilyTests`. They contribute
to the live risk field and the tappable hazard summary; they stay silent when
the hazard is absent (e.g. avalanche zones read off-season in summer).

| Family | Feed(s) | Coverage | Scoring |
|---|---|---|---|
| **tropical** | NHC `CurrentStorms.json` | US/CA/MX/Caribbean coasts | nearest active storm, intensity (kt) × distance, reach grows with category |
| **volcanic** | USGS HANS elevated volcanoes + curated NA/CA coordinate table | US live status; MX/Central-America status via CAP alerts | nearest elevated volcano within ~80 km × alert level (ADVISORY/WATCH/WARNING) |
| **avalanche** | Avalanche.org (US polygons) + Avalanche Canada (per-region bbox) | US + Canada mountain west | danger rating (EAWS 1–5) of the zone the point falls inside |
| **tsunami** | NWS Tsunami Warning Centers NTWC (PAAQ) + PTWC (PHEB) CAP/Atom | US/Canada/Caribbean/Pacific | active warning/watch/advisory near the event epicenter (Information statements score 0) |

Mexico/Central-America/Caribbean *status* for volcanic and many other hazards
flows through the WMO Alert Hub CAP feed (see §7), since national agencies there
(CENAPRED, INSIVUMEH) are bot-gated or HTML-only.

## 7. Cross-country sweep (sweep 2) — verified catalog

A 14-domain, 29-agent discovery+live-verification pass across all countries. **72 sources verified live & keyless**, 16 free-key, 10 gated/unverifiable, 6 dead. Every row was probed; classification reflects the actual payload (a 200 wrapping a token/error body is *not* counted live).

### Live & keyless (ready to wire)

| Source | Countries | Fills / improves |
|---|---|---|
| Australia NSW FuelCheck — Real-time Fuel Prices (open snapshots) | Australia | capability: fuel (mandatory-reported retail prices at 2,500+ NSW stati |
| Australia WA FuelWatch — Daily Price RSS Feed | Australia | capability: fuel (statutory next-day-fixed retail prices per station; |
| Austria E-Control — Spritpreisrechner public Sprit API | Austria | capability: fuel (regulator-mandated station price database; diesel & |
| EAWS aggregated avalanche bulletins (static CAAML/JSON archive) | Austria/Switzerland/Italy/France | NEW risk family: avalanche (mountain snow-slope hazard). Pan-European |
| ECCC MSC GeoMet — hydrometric-realtime (OGC API - Features) | Canada | qpf_flood (river/streamflow observation) — road-weather/flood hazard |
| Québec MSP Vigilance — hydrometric stations WFS | Canada | qpf_flood — provincial river-flood monitoring with flood-threshold sta |
| Earthquakes Canada (CNSN) FDSN Event Web Service | Canada | seismic (fills Canada gap; USGS under-reports small/moderate Canadian |
| ECCC AQHI Observations & Forecasts (GeoMet-OGC-API) | Canada | air (Canada Air Quality Health Index, 1-10+ scale; forecast twin at aq |
| New Brunswick EUB — Maximum Allowable Petroleum Prices | Canada | capability: fuel (regulated maximum retail gasoline/diesel/furnace-oil |
| Nova Scotia Energy Board — Weekly Regulated Petroleum Prices by Zone | Canada | capability: fuel (weekly min/max regulated gasoline & diesel across 6 |
| PEI IRAC — Maximum Consumer Petroleum Price Schedule | Canada | capability: fuel (regulated min/max gasoline & diesel, max furnace-oil |
| NRCan — Weekly Transportation Fuel Prices (downloadable spreadsheet) | Canada | capability: fuel (federal weekly average retail gasoline & diesel acro |
| NRCan Corridor Public Charging Planning Map (ZEVIP) | Canada | capability: EV charging (corridor gap/priority planning, NOT a station |
| Le Circuit Électrique station export | Canada | capability: EV charging (existing public stations, Québec + some Atlan |
| City of Vancouver EV Charging Stations | Canada | capability: EV charging (municipal existing stations) |
| City of Victoria EV Charging Stations | Canada | capability: EV charging (municipal existing stations, BC island) |
| Hydro-Québec Open Data portal | Canada | capability: road-hazard/outage context (utility-original). NOTE: no EV |
| DriveBC Open511 API | Canada | capability:traffic (incidents/closures/CONSTRUCTION/ROAD_CONDITION), w |
| Québec 511 / MTQ MapServer WFS | Canada | capability:traffic (ms:evenements incidents/closures, ms:chantiers con |
| 511 Alberta REST API | Canada | capability:traffic (events/closures/roadwork), capability:POI (/api/v2 |
| Ontario 511 REST API | Canada | capability:traffic (events/closures/construction), capability:POI (/ap |
| Ontario 511 Truck Rest Areas & Inspection Stations | Canada | capability: truck-parking availability + rest-area/weigh(inspection)-s |
| VIA Rail Canada GTFS Schedule | Canada | capability: transit (national/intercity rail schedules — Canada) |
| NAAD System public GeoRSS/CAP feed (Alert Ready upstream) | Canada | Cross-family CAP all-hazards for Canada (wind, convective/storm, winte |
| Avalanche Canada public products API | Canada | NEW family avalanche - danger ratings by forecast region across BC/Alb |
| Earthquakes Canada real-time earthquake feed (NRCan FDSN) | Canada | seismic - authoritative Canadian earthquake catalogue (Canadian Nation |
| ECCC Water Office / MSC hydrometric real-time (water level & flow) | Canada | qpf_flood - Canadian real-time river gauges (level + discharge), Canad |
| 511 Alberta Weather Stations (RWIS) | Canada | winter / road-weather capability (RWIS pavement-temperature sensors) |
| 511 Alberta Winter Roads (road-surface condition) | Canada | winter (segment-level road-surface driving condition) |
| Ontario 511 Road Conditions | Canada | winter (segment-level road-surface driving condition) |
| DriveBC Open511 (extreme-weather & winter road events) | Canada | winter / convective-storm (road events incl. snow, ice, extreme-weathe |
| NRCan Emergency Geomatics — Active Floods in Canada | Canada | qpf_flood (Canada coverage) — satellite (SAR/RCM) derived near-real-ti |
| Transport Canada Grade Crossings Inventory | Canada | New capability: rail-crossing hazard (Canada) — Canadian counterpart t |
| SINCA — Sistema de Informacion Nacional de Calidad del Aire | Chile | air (Chile national station catalog + realtime MP10/MP2.5/O3/SO2/NO2/C |
| Smithsonian/USGS GVP — Volcanoes of the World (WFS/GeoJSON) | Global/Mexico/Central America/Caribbean | volcanic — global inventory; covers Mexico/Central America/Caribbean w |
| WMO CAP Alerts Feed (Alert Hub via ESRI CAP Connector) | Guatemala/Belize/Honduras/El Salvador | ALL hazard families as official CAP alerts (wind, qpf_flood, convectiv |
| Icelandic Met Office avalanche forecast (EAWS IS region) | Iceland | NEW risk family: avalanche. High-latitude North-Atlantic winter road/m |
| CONAFOR IDEFOR GeoServer (national forest fire authority, Mexico) | Mexico | fire (official Mexican forest-fire incidents / perimeters) |
| SSN Ultimos Sismos RSS | Mexico | seismic (authoritative Mexico earthquakes, minutes after event) |
| CFE Electrolineras Públicas en México | Mexico | capability: EV charging (fills FLOWS's zero Mexico EV-charger coverage |
| Red Nacional de Caminos (RNC) - INEGI WMS (road network + structures) | Mexico | capability: commercial-vehicle road network + structure data for Mexic |
| Copernicus GloFAS river discharge via Open-Meteo Flood API | Mexico/Guatemala/Belize/Honduras | qpf_flood — per-coordinate riverine-flood forecast for Central America |
| Smithsonian/USGS Global Volcanism Program - Volcanoes of the World WFS | Mexico/Guatemala/El Salvador/Nicaragua | NEW risk family: volcanic. Fills Mexico/Central America/Caribbean geog |
| NVE Varsom avalanche warnings (RegObs/Forecast API) | Norway/Svalbard | NEW risk family: avalanche (plus sibling landslide/quick-clay/river-ic |
| Spain MINETUR — Precios de Carburantes REST (all terrestrial stations) | Spain | capability: fuel (real-time per-station prices for all ~11,000 Spanish |
| SLF Swiss avalanche bulletin (CAAML API) | Switzerland/Liechtenstein | NEW risk family: avalanche. National-authority Swiss/Alpine source wit |
| Caltrans CWWP2 — Lane Closure System (LCS) + CCTV + Chain Control | US | capability:traffic (lane/ramp closures), capability:POI (cctvStatusD{N |
| Iowa 511 — public WZDx work-zone feed | US | capability:traffic (WZDx work zones / construction closures — GeoJSON) |
| NWS Marine / Coastal & Offshore alerts (active, marine filter) | US coastal + Great Lakes/Puerto Rico/USVI coastal/Gulf of Mexico | wind + coastal/road-weather — surf/coastal-flood/high-wind/small-craft |
| US Drought Monitor GeoJSON (current conditions polygons) | United States | NEW capability: drought/fire-precursor — weekly D0-D4 drought-intensit |
| USGS Volcano Hazards Program — HANS Elevated Volcanoes API | United States | volcanic — real-time US aviation color code + alert level |
| NTAD Interstate Truck Stop Parking Areas | United States | capability: truck-parking / rest-area POI (static nationwide inventory |
| NTAD Weigh-in-Motion (WIM) Stations | United States | capability: commercial-vehicle weigh-station / WIM locations (with ann |
| BART GTFS-Realtime | United States | capability: transit (SF Bay Area heavy rail — trip updates and service |
| SEPTA GTFS-Realtime | United States | capability: transit (Philadelphia multimodal — vehicle positions, trip |
| USGS Volcano Hazards Program HANS API (elevated volcanoes + notices) | United States | NEW family volcanic - US volcano alert level (NORMAL/ADVISORY/WATCH/WA |
| FEMA IPAWS All-Hazards Information Feed (US non-weather CAP) | United States | Capability: civil-emergency / AMBER / WEA / local-EM CAP + backup NWS |
| NTAD Railroad Grade Crossings (National Highway-Rail Crossing Inventory) | United States | New capability: rail-crossing hazard — score routes for at-grade rail |
| California Evacuation Aggregation Layer (Cal OES) | United States | New capability: evacuation — live EVACUATION ORDER/WARNING/SHELTER-IN- |
| NWS HeatRisk (experimental 7-day heat-impact index) | United States | heat (upgrade) — gridded 0-4 CONUS heat-impact surface with multi-day |
| USACE National Inventory of Dams (NID) — public feature service | United States | qpf_flood (upgrade) — high-hazard-potential dams upstream of a route; |
| SPC Convective Outlooks MapServer (categorical + probabilistic, Days 1-8) | United States (CONUS) | convective/storm — day-1..day-8 severe-weather risk polygons (TSTM/MRG |
| WPC Quantitative Precipitation Forecast MapServer | United States (CONUS) | qpf_flood + winter — official 6/24/72/120/168-hr rainfall-accumulation |
| NWS NDFD gridded forecast REST service (DWML) | United States (CONUS, Alaska, Hawaii, Puerto Rico, Guam) | road-weather / multi-family — gridded numeric forecast (wind speed+gus |
| NOAA NTWC PAAQ Atom/CAP feed | United States/Canada | tsunami — continental US, Alaska, Canadian Pacific/Atlantic coasts |
| US Tsunami Warning Centers CAP feeds (NTWC PAAQCAP + PTWC PHEBCAP) | United States/Canada/Caribbean (US/British Virgin Islands, Puerto Rico)/Pacific basin nations | NEW family: tsunami — coastal-hazard coverage for Caribbean and Pacifi |
| GDACS Global Disaster Alert & Coordination System GeoRSS/JSON feed | United States/Canada/Mexico/Guatemala | NEW families tropical-cyclone, tsunami, volcanic, seismic + qpf_flood |
| NOAA Tsunami Warning Centers CAP / Atom feeds (NTWC PAAQ / PTWC PHEB) | United States/Canada/Puerto Rico/US Virgin Islands | NEW family tsunami - NTWC (PAAQ) covers continental US/Alaska/Canada c |
| Washington VAAC volcanic ash advisories (messages index) | United States/Mexico/Central America/Caribbean | NEW family: volcanic (ash) — Central American volcanic arc + Caribbean |
| NOAA PTWC PHEB Atom/CAP feed | United States/Puerto Rico/US Virgin Islands/British Virgin Islands | tsunami — Hawaii, US Pacific & Caribbean territories, Caribbean Basin |
| GWIS Current Situation / EFFIS WMS (claimed active-fire + burnt-area) | global/Mexico/Guatemala/Honduras | fire-danger / fire-weather (FWI, Haines, Mark5, NFDRS) - NOT the claim |
| GWIS / JRC Copernicus Fire Danger WMS (Fire Weather Index forecast) | global/United States/Canada/Mexico | fire-danger / fire-weather rating (forecast, global FWI) |

### Free but need a free key

| Source | Countries | Fills / improves |
|---|---|---|
| NASA FIRMS Area/Country API (VIIRS + MODIS active fire) | United States/Canada/Mexico | fire (active-fire detection) |
| NASA FIRMS Mapserver WMS/WFS (hotspots) | global/Canada/Mexico | fire (active-fire map overlay / hotspot tiles) |
| CAMS Global Atmospheric Composition Forecasts (wildfire smoke / PM2.5 / AOD) | global/United States/Canada | wildfire-smoke / PM2.5 / AOD forecast (also feeds air quality) |
| Avalanche.report ALBINA live bulletins API | Austria (Tyrol)/Italy (South Tyrol / Bolzano, Trentino) | NEW risk family: avalanche. Live trans-border Alpine bulletins — |
| US state 511 platform (Castle Rock/ibi511) — 511NY etc. | US | capability:traffic (events), capability:POI (/api/v2/get/cameras) |
| WSDOT Traveler Information API — Highway Alerts | US | capability:traffic (HighwayAlerts), capability:POI (Cameras), win |
| OHGO Truck Parking (Ohio DOT TPIMS / MAASTO) | United States | capability: real-time truck-parking availability (live space coun |
| Iowa DOT 511 Truck Parking Availability | United States | capability: real-time truck-parking availability (Iowa Interstate |
| Kansas DOT TPIMS Truck Parking | United States | capability: real-time truck-parking availability (I-70 and I-135 |
| Transitland REST API — GTFS-Realtime catalog + snapshot download | United States/Canada/Mexico | capability: transit (aggregated GTFS/GTFS-RT feed catalog + norma |
| MTA NYC Subway GTFS-Realtime | United States | capability: transit (NYC subway trip updates / vehicle positions |
| Metrolinx GO Transit & UP Express GTFS-Realtime (Open Metrolinx) | Canada | capability: transit (Greater Toronto–Hamilton commuter rail + UP |
| STM Montréal GTFS-Realtime v2 | Canada | capability: transit (Montréal metro + bus — vehicle positions, tr |
| FHWA Weather Data Environment (WxDE) | United States | winter / road-weather capability (national RWIS + mobile road-wea |
| MADIS RWIS/Clarus dataset | United States/Canada | winter / road-weather capability (RWIS atmospheric + pavement obs |
| Saskatchewan Highway Hotline (road conditions / ice roads) | Canada | winter (road-surface condition, ice roads, plow tracking) |

### Gated / unverifiable / dead (diagnosed, not assumed)

- **CONAGUA SINA — Estaciones Hidrométricas (ArcGIS REST MapServer)** [Mexico] — `unverifiable`: DNS resolves (201.116.60.30) and www.conagua.gob.mx returns 302, but the mapasina host never completes a TCP handshake on 443 (connect time 0.0, repea
- **INSIVUMEH — Guatemala hydrology / river-level monitoring** [Guatemala] — `unverifiable`: Page loads as a WordPress HTML bulletin ('Boletín hidrológico – INSIVUMEH'). No keyless JSON/WFS/ArcGIS API surfaced — grep of the page found only fon
- **Central America Flash Flood Guidance System (CAFFGS)** [Costa Rica/El Salvador] — `token_gated`: The endpoint is an ArcGIS web-map VIEWER URL, not a data API. Fetching the underlying item data (arcgis.com/sharing/rest/content/items/a8e75c0c.../dat
- **CATAC — Central America Tsunami Advisory Center (INETER)** [Nicaragua/Costa Rica] — `unverifiable`: Homepage returns 200 text/html (title 'Centro de Asesoramiento para Alerta de Tsunami en America Central'), valid over both plain and -k. But NO keyle
- **CENAPRED Popocatepetl volcano monitoring report** [Mexico] — `token_gated`: 302 redirects to validate.perfdrive.com (Radware Bot Manager), serving a `Radware Captcha Page` (shieldsquare/perfdrive JS challenge, botmanager_suppo
- **WAQI / aqicn.org global feed API** [Global/United States] — `token_gated`: HTTP 200 valid JSON {"status":"ok","data":{"aqi":55,"iaqi":{"pm25":{"v":55},...},"attributions":[national agency URLs]}}. Requires a token: 'demo' is
- **SISAIRE — Subsistema de Informacion sobre Calidad del Aire** [Colombia] — `unverifiable`: HTTP 200 but text/html — a PrimeFaces/JSF page shell (<!DOCTYPE html>...primefaces-apollo-blue-light theme), not data. No machine-readable JSON/CSV/Ge
- **SINAICA — Sistema Nacional de Informacion de la Calidad del Aire** [Mexico] — `unverifiable`: datGrafs.php returns HTTP 200 text/html — a JS-embedding page fragment (var tipoDato={valido:0,manualAut:1,crudo:2}...), NOT JSON. Every rsinaica-styl
- **CDMX Datos Abiertos — GTFS static + Metrobús GTFS-Realtime** [Mexico] — `unverifiable`: Connection timed out after 20s and 30s (HTTP 000). DNS resolves (189.240.234.183) but host is unreachable — ICMP ping 100% packet loss. Looks like a t
- **Mexico Atlas Nacional de Riesgos / CENAPRED** [Mexico] — `unverifiable`: The exact candidate path returns Apache 404 (Not Found). The host itself is alive (root '/' returns 200 HTML web-app), but the standard ArcGIS path /a
- **Alberta Rivers — basins.json** [Canada] — `dead`: Host is live but this exact path returns IIS '404 - File or directory not found.' The guessed /data/Program/basins.json path does not exist; the real
- **CONABIO SATIF - heat points (puntos de calor), Mexico + Central America** [Mexico/United States] — `dead`: DNS resolves (geonode.conabio.gob.mx -> 200.12.166.58) but server refuses all connections on port 80 and 443 ('Failed to connect ... Couldn't connect
- **SIMAT / RAMA — Red Automatica de Monitoreo Atmosferico (Mexico City)** [Mexico] — `dead`: HTTP 404 text/html (Apache/2.2.15 CentOS): 'The requested URL /opendata/catalogos/cat_estacion.csv was not found on this server.' Same over http and h
- **FMCSA National Hazardous Materials Route Registry** [United States] — `dead`: Persistent HTTP 503 'Service Temporarily Unavailable' across ~6 attempts over several minutes on the query path, MapServer root (?f=json), and the /Ar
- **BC RWIS Optical / Weather Network Program** [Canada] — `dead`: Hostname does not exist: public resolver 8.8.8.8 returns 'server can't find rwis-optical.th.gov.bc.ca: NXDOMAIN', while parent 'th.gov.bc.ca' resolves
- **PHMSA Hazmat Incident Reports (Form 5800.1) — Socrata** [United States] — `dead`: Socrata resource API returns 403 {"error":true,"message":"no row or column access to non-tabular tables"}. Asset metadata (/api/views/rxrf-q3m4.json)


### Highest-value wire-next from sweep 2 (keyless, map to existing systems)

- **WMO Alert Hub CAP feed** + **Canada NAAD (Alert Ready upstream)** + **GDACS** + **FEMA IPAWS** — official CAP alerts for ~100 countries incl. all of Central America + the Caribbean, plus Canada all-hazards and US civil/AMBER. These extend the *existing* alert pipeline (`WeatherAlertService`) to every country with no standalone API. Highest single leverage.
- **NTAD** truck-stop parking, weigh/WIM stations, railroad grade crossings (the *correct* public `services.arcgis.com/xOi1kZaI0eWDREZv` endpoints the sweep found — my earlier guesses were wrong service names).
- **SPC convective outlooks**, **WPC QPF**, **NWS HeatRisk**, **US Drought Monitor** — upgrade the convective / qpf_flood / heat / fire families with official forecast polygons.
- **ECCC hydrometric-realtime** + **NRCan Active Floods** — Canada flood, parallel to the US NWPS gauges already wired.
- **Earthquakes Canada** + **SSN México** — denser seismic than USGS in CA/MX (USGS already covers the NA bbox).
- **ECCC AQHI** — official Canadian air quality (vs. modeled Open-Meteo).
- **Provincial 511s** (DriveBC Open511, 511 Alberta, Ontario 511, Québec MTQ) — incidents, closures, winter road-surface conditions, RWIS.
- **VIA Rail GTFS**, **BART/SEPTA GTFS-RT** (keyless) + **MTA/Metrolinx/STM** (free key) — transit realtime.
- **CFE Electrolineras** (Mexico EV) + **NRCan/Circuit Électrique** (Canada EV) — EV charging where FLOWS has none.

---

## 8. Calibration + fixes pass

### Sweep post-mortem (why the critic stage failed, what was missed)
The 14-domain sweep ran 29 agents; **exactly one stage errored** — the
`completeness-critic` (`API Error: Connection closed mid-response`, attempt 1).
Cause: it was handed the full 104-source JSON (~104 KB) and the response was
truncated mid-stream. Because it produced no gap list, the downstream **Fill**
phase spawned 0 agents — so in the run view it reads as two incomplete phases
(Critic errored, Fill empty), though only one agent actually failed. The
original task-notification also truncated the *result* at ~74 KB, but the full
result was recovered from the run's result file, so no verified source was lost.

The critic was **re-run** with a compact catalog (names + country + mapsTo only,
~15 KB) and completed. Its findings: most Mexico / Central-America / Caribbean
"unverifiable" gaps are already **covered by keyless globals** already wired or
identified — Open-Meteo AQI + CAPE (live-verified over Mexico City), GloFAS
flood, GDACS disasters, and the SMN gridded forecast. The genuinely open gaps
with **no** verified keyless feed are narrow: (a) Mexico real-time highway
incidents/closures, (b) Popocatépetl driving-closure / ashfall status
(CENAPRED is bot-gated), (c) Mexico's own national CAP alert stream (SMN CAP is
server-blocked; reachable only via the GDACS/WMO aggregate today).

### Proportionality — acute families banded to lethality
The acute-family sub-risk curves were recalibrated so a level's score lands in
the band that matches its threat to life while driving (bands: green ≥ 0.398,
yellow ≥ 0.699, red > 0.8751). Pinned by `testFamilyProportionalityToBands`.

| Family | green | yellow | red |
|---|---|---|---|
| tropical | dep. / storm | Cat 1–2 | **Cat 3+ (major)** |
| avalanche | Low / Moderate | **Considerable (most deaths)** | High / Extreme |
| volcanic | Advisory (unrest) | Watch (eruption) | **Warning (hazardous)** |
| tsunami | — | Watch / Advisory | **Warning (evacuate)** |
| convective (SPC) | TSTM / MRGL / SLGT | ENH | **MDT / HIGH (outbreak)** |

Weights (for the R-parity noisy-OR) rank by un-outrunnable-in-a-vehicle threat:
tsunami 0.97 ≈ flood 0.96 > tropical 0.94 ≈ convective 0.92 > volcanic 0.90 >
winter 0.88 > avalanche 0.86 > seismic 0.78 > fire 0.74 > heat 0.70 > cold 0.66
> wind 0.64 > air 0.60 > radiation 0.52.

### Normalized environmental red-threshold — preserved
The `environmental` score is still `forecastComposite = min(1, 0.45·temp +
0.30·wind + 0.25·pop)` — a weighted average that structurally needs *very high*
temp AND wind AND precip to approach red. All new families are **separate keys**;
none fold into `environmental`. An acute family (a tsunami warning, a HIGH
convective outlook) can legitimately color a point red on the worst-hazard field
— but the normalized-environmental score and its choropleth keep the exact
high-bar-for-red calibration set previously. Unchanged.

### Feed added this pass
- **SPC Day-1 categorical severe outlook** (`mapservices.weather.noaa.gov`,
  keyless, verified) → `convective` family. Point-in-polygon over the
  TSTM/MRGL/SLGT/ENH/MDT/HIGH outlook; `convective` = worse of the forecast
  signal and the official outlook. (Mexico/Central-America convective already
  comes from the SMN-chain forecast; **NRCan Active Floods** was NOT wired — its
  MapServer path now 500s "Service not found", so it's deferred pending the
  current endpoint.)

### Review fixes (from the adversarial pass)
- `familyWeights` gained a `qpf_flood` alias (= 0.96) so noisy-OR resolves the
  app's flood key, not just the R-export `flood` key.
- Tsunami parser now scans the whole feed for the strongest level word and
  excludes cancellations, instead of trusting one `<title>`'s position.
- The tappable hazard icon now gives an **acute** family (fire/tsunami/…) icon
  priority at yellow+ over the blended forecast kind.
- Noted the ray-cast's antimeridian limitation (not reached by NA-boxed feeds).

---

## 9. WMO Alert Hub — official alerts for Mexico + Central America + Caribbean

**Correction:** §8 said Mexico's national CAP stream was server-blocked. That
was wrong — the recovered critic (re-run after the connection failure) found it
live and keyless on the **WMO Alert Hub**, verified:
`https://severeweather.wmo.int/v2/cap-alerts/mx-smn-es/rss.xml` returns real
`cap:`-namespaced SMN/CONAGUA alerts. (The earlier "blocked" verdict came from
probing the wrong host — `correo1.conagua.gob.mx` and an S3 path that 404s.)

**Wired** (`WMOAlerts.swift` + `WMOAlertCache` in `WeatherAlertService.swift`):
the alert chain is now **NWS (US) → ECCC (Canada) → WMO Alert Hub (Mexico +
Central America + Caribbean)**. `api.weather.gov` 400s off-US, so the chain
falls through cleanly. Per-country feeds verified live on the canonical host:
Mexico `mx-smn-es`, Panama `pa-imhpa-es`, Costa Rica `cr-imn-es`, Dominican
Republic `do-indomet-es`, Belize `bz-nms-en`, Jamaica `jm-jms-en`, Trinidad &
Tobago `tt-ttms-en`.

Mechanics: the RSS is a country-wide index with `cap:severity`/`event`/`expires`
inline but geometry only in each item's linked CAP file. So `WMOAlertCache`
fetches the RSS, keeps unexpired items, fetches the **24 most-recent** items'
CAP files (bounded — the polygons live there), and caches the parsed alerts
per country for 10 min; `wmoAlerts(at:)` then keeps the ones whose polygon
contains the driver's point (point-in-polygon). This fetches once per country,
not per corridor sample.

**Confirmed hard coverage floor** (no keyless feed — only GDACS spans them, at
disaster scale): Guatemala, Honduras, El Salvador, Nicaragua, Cuba, Haiti — none
are registered on the WMO Alert Hub. **Mexico's two residual driver gaps** with
no keyless primary: real-time highway incidents, and Popocatépetl driving/ash
status (CENAPRED bot-gated); Smithsonian GVP covers volcano inventory, VAAC
covers ash advisories.

### Coverage reality (verified against live CAP payloads)
The hub feeds are wired, but a national CAP alert is only *placeable on the map*
when it carries a `<polygon>`. Verified live: **Mexico, Jamaica, and Trinidad**
publish polygon CAP (spatial filtering works end-to-end); **Dominican Republic**
publishes geometry-less CAP (no `<area>`), so its alerts are safely skipped
rather than smeared country-wide. Panama / Costa Rica / Belize had no active
alerts at check time (calm period) but are peer national services expected to
carry polygons. The pipeline requires a polygon (no false positives) — a
geocode→boundary lookup to also place geocode-only feeds is a documented future
option. Feed ordering is newest-first; the code filters **all** items to
unexpired first, then bounds to 24, so active alerts deep in the list aren't
missed.

---

## 10. Request discipline + device-adaptive tuning

With this many live feeds, two failure modes had to be closed: barraging a
source (getting rate-limited / IP-banned — Overpass and the ArcGIS hosts are
strict) and overworking an old device. Both are now handled centrally.

### One throttled HTTP path (`ThrottledNet.swift`)
Every network fetch in the app went through its own `URLSession` — 8+ of them,
each with an independent per-host connection budget, so a viewport sweep could
open dozens of sockets to one host. They are now **one** shared session
(`httpMaximumConnectionsPerHost = 3`, sane timeouts, `waitsForConnectivity`),
and every fetch passes through a **global concurrency gate** (`RequestGate`, an
async counting semaphore) sized to the device. No matter how wide a fan-out —
the viewport hazard grid, a corridor's alert points, a route's elevation
samples — only a device-appropriate number of requests are ever in flight; the
rest queue for a slot instead of piling on. Migrated: LiveHazardFeeds, Weather-
AlertService + WMO, NWSForecast, RouteAttributes, RadarLoop, ZipBorders/TomTom,
PrimarySources, EPA vehicle DB, Yelp, Smartcar, radio scrape. (`grep`:
exactly one `URLSessionConfiguration` remains.)

### Device-adaptive tuning (`AdaptiveTuning.swift`)
A single source of truth maps the device + its live state to how hard FLOWS may
work. **Base tier** from `activeProcessorCount` + `physicalMemory` (iPhone 7 /
A10 / 2 GB → *low*; A12–A13 / 4 GB → *standard*; A14+/M-series → *high*).
**Dynamic backoff** from `thermalState` and `isLowPowerModeEnabled`, observed at
runtime — a phone that heats up on a long drive throttles itself automatically.

| Setting | low | standard | high | hot / low-power |
|---|---|---|---|---|
| Viewport grid | 3×3 | 4×4 | 5×5 | −1 step |
| Max concurrent requests | 3 | 6 | 10 | halved (min 2) |
| Cache-TTL multiplier | 1.0× | 1.0× | 1.0× | ×2 (fair 1.3×, critical 3×) |
| Refresh debounce | 1.0 s | 0.6 s | 0.4 s | ≥1.0 s |

Applied at: the viewport grid density + a time-debounce (a fast diagonal pan no
longer kicks a sweep per cleared cell); every hazard-feed / alert-cache / NWS
TTL (`AdaptiveTuning.ttl(base)`); the corridor-alert concurrency cap (was a
hardcoded 6); and the live-navigation corridor-watch cadence. The tier→settings
mapping and the gate's concurrency-cap invariant are pinned by
`AdaptiveTuningTests`.

### Per-feed politeness (unchanged, verified)
National feeds are one fetch on a long TTL (fire 30 m, quakes 5 m, avalanche
3 h, SPC 1 h…); viewport feeds are bbox-cell cached; `airAndUV` now **coalesces**
in-flight duplicates so a 25-point grid landing in one ~50 km cell makes one
request pair, not 25. WMO CAP is one fetch per country per 10 min (bounded to 24
CAP files). Overpass keeps its 3-mirror fallback and now rides the global gate.

**Remaining lower-priority follow-ups:** a persistent bbox cache for the
RouteAttributes Overpass clearance query (re-queried on each route recalc — the
gate bounds it, a cache would cut repeats), and radar-tile reuse across pans if
RainViewer is kept.

---

## 11. RainViewer — settled: removed

The radar loop rode on **RainViewer**, a third-party *broker* — at odds with
this document's whole premise (go to the primary/government source) — and the
audit flagged its tile stitching as a HIGH barrage risk (~192 tile fetches per
pan). Investigation showed it was already **dead code**: an earlier removal was
partial, leaving `RadarLoopService` instantiated but never driven
(`begin()`/`stitch()` were never called) and the two overlay views defined but
never mounted. So it fetched nothing and only added weight and a reverted-artifact
risk.

**Removed:** `RadarLoop.swift`, the service wiring in `FLOWSApp`, the
`flows.showRadarLoop` toggle, the dead `radarOverlay`/`radarTimestamp` views, and
the `RadarTiles` unit test. If animated radar is wanted as a deliberate feature
later, **NOAA MRMS** (the government radar mosaic, verified live in the sweep) is
the primary-source path — no third-party broker.

### RouteAttributes Overpass clearance cache (follow-up, done)
The low-bridge clearance query (`clearances(inBoxes:)`) now has a bbox-keyed,
6-hour TTL cache (device-stretched). Bridges are static infrastructure, so
re-scoring the same route no longer re-queries the rate-limited Overpass API;
only successes are cached (a failure stays retryable).

---

## 13. Radio + music expansion (2026-08) — AM/FM, scanner, Spotify remote

### AM/FM stations — radio-browser.info (keyless, wired)

The Emergency/Trucker radio card carried NOAA relays only; it now also
searches the **radio-browser.info** community directory (`RadioBrowser.swift`).
All endpoints probed live before wiring:

- **Mirror discovery:** `https://all.api.radio-browser.info/json/servers`
  returns the mirror list (one row per IP family). Per the project's API
  etiquette, FLOWS fetches that list at runtime, shuffles it, and picks the
  first mirror whose `/json/stats` answers `{"status":"OK"}` (verified:
  `de1.api.radio-browser.info`, 57k stations). The all-servers name itself
  (DNS round-robin over the same mirrors) is the fallback host — never a
  hardcoded mirror.
- **Search:** `/json/stations/search?countrycode=US&hidebroken=true&`
  `is_https=true&order=votes&reverse=true` + `state=` (vehicle's state) or
  `name=` (free text). US-only structurally satisfies the no-RU/CN/IR/NK
  rule; `is_https` is re-checked client-side (probe: ~half of a state's
  entries are cleartext — ATS would block them, so they're filtered, not
  scheme-upgraded: unlike the NOAA relay hosts, arbitrary station hosts
  don't all serve TLS).
- **Playback** rides the existing TruckerRadio AVPlayer path (same
  plain-words offline text, same one-stream-at-a-time rule as NOAA).

### Police/fire/EMS scanner — Broadcastify (link-out ONLY, diagnosed)

Broadcastify's terms allow **no keyless stream API** — feeds are their
product. Diagnosis of the public URL space (all probed live): county pages
exist only as internal sequential ids (`/listen/ctid/2523` — NOT derivable
from FIPS; mapping them would mean scraping every state page), state
directories are `/listen/stid/<state FIPS>` (48 → Texas verified), and
`/listen/near/` is their own "Feeds Near Me" player page, which locates the
driver via the browser and lists that county's feeds. FLOWS therefore links
OUT to `/listen/near/` (`ScannerLinks`) — no in-app scanner audio, and the
card says so in plain words, including that scanner-listening law varies by
state and it must not be used while driving where prohibited.

### Spotify remote — optional user token (the Yelp/TomTom pattern)

True in-app Spotify control on iOS needs Spotify's own iOS SDK + a client
key — a dependency this repo doesn't take. Instead (`SpotifyRemote.swift`):
a **user-supplied Web API token** (Settings → Data sources, Keychain-stored
via SecureStore — a bearer token is a credential) lights up play / pause /
skip / shuffle against `api.spotify.com/v1/me/player/*` on the user's active
Spotify device. Needs Premium; tokens expire ~hourly — every failure mode
maps to one plain-words fix (`SpotifyWebAPI.plainWords`). Without a token
the mini player keeps the honest "Open Spotify" button. macOS is untouched:
Spotify.app is still scripted directly over Apple Events.

---

## Deployment posture: keyless / open-source / politely-scraped first (2026-07)

Keyed APIs are OPTIONAL enrichment only; the app must deploy fully without any
key. Gap-filling sources adopted under this rule:

| Gap | Source | Access | Status |
|---|---|---|---|
| Live fuel prices | **AAA state averages** (gasprices.aaa.com, public posting) | Keyless polite scrape, 12-h cache per state (`AAAFuelPrices`) | **Wired** — overrides the static state-factor estimates; still labeled "est." (state average, not station price) |
| POI database | **Foursquare OS Places** (Apache 2.0, ~106M POIs) | Keyless bulk download → regional `.fps` shards | Pipeline in `scripts/build_places_shards.sh` (see section below); Swift reader next |
| POI database (alt/merge) | **Overture Maps Places** (CDLA-P-2.0/Apache 2.0) | Keyless GeoParquet on S3/Azure | Candidate for a future merge pass |
| Transit fares | GTFS `fare_*.txt` where agencies publish | Keyless (rides the GTFS→.ftt pipeline) | Parser slot reserved |
| Streamflow depth | USGS Water Services IV | Keyless | Not wired: raw gauge height lacks flood-stage context; NWPS (already wired) supplies categorized flood levels |
| Closures (non-WZDx states) | State 511 sites | Mixed (some keyless, some free-key) | WZDx registry covers the open-feed states; per-state 511 keys deliberately skipped |

### Optional free keys (enrichment only — NOT required to deploy)

**Google Places API (New)** — POI star ratings / price / hours (primary ratings provider):
1. console.cloud.google.com → create/select a project.
2. "APIs & Services" → "Library" → enable **Places API (New)**.
3. "Credentials" → "Create credentials" → API key; restrict it to Places API (New).
4. Billing account required for activation, but the per-SKU free monthly tier
   (thousands of Text Search calls) covers per-search app use without charges.
5. Paste into FLOWS → Settings → Data sources → Google Places key.

**EIA (fuel-price series, stabler than scraping)** — api.eia.gov:
1. https://www.eia.gov/opendata/register.php → email → key arrives instantly.
2. Weekly retail gasoline/diesel by state: `/v2/petroleum/pri/gnd/data`.
(Currently unused — AAA scrape covers it keylessly; keep as backup.)

**NPS (parks detail for Tourist stops)** — developer.nps.gov:
1. https://www.nps.gov/subjects/developer/get-started.htm → sign up → instant key.
(Optional: FSQ Places shards already carry parks/landmarks keylessly.)

**Recreation.gov RIDB (federal campgrounds/rec areas)** — ridb.recreation.gov:
1. Create a recreation.gov account → profile → "API" → generate key.
(Optional, same reason as NPS.)

---

## 12. FSQ OS Places → offline POI shards (`.fps`) — owned

FLOWS's own offline, legally-shippable POI database: **Foursquare OS Places**
(Apache 2.0, ~106M global POIs) filtered to US places in the eight groups the
app actually offers, compiled into one binary shard per state. Replaces
dependence on keyed POI APIs; ships with the app; works with zero network.

### Source + the gating caveat (2026-07)

Foursquare's own distribution moved: the original public S3 bucket
(`fsq-os-places-us-east-1`) now holds **only** `LICENSE.txt` and `NOTICE.txt`,
and current monthly releases (e.g. `dt=2026-07-09`) live in a **gated**
Hugging Face dataset (`foursquare/fsq-os-places`) requiring an account plus an
agreement that includes marketing use of the licensee's name. FLOWS builds
from the last ungated, keyless mirror instead:

- **Mirror:** Source Cooperative, `fused/fsq-os-places`
  (`https://data.source.coop/fused/fsq-os-places/<release>/places/*.parquet`),
  Apache 2.0 confirmed in the mirror's own README. Latest mirrored release:
  **2025-02-06** (81 parquet files, 16.9 GB global).
- POIs age slowly; a 2025 snapshot is fine. If fresher data is ever wanted,
  a human can accept the HF gate and point the tooling at that copy.

### Pipeline (one command)

```
scripts/build_places_shards.sh [release]      # default: latest on the mirror
```

1. **Tooling conversion** (`scripts/fsq_places_to_tsv.py`, python + duckdb —
   REPO TOOLING only, never a product dependency): remote *filtered* scan.
   Parquet footers are read first, so files whose `country` column stats
   cannot contain `'US'` are skipped wholesale (34 of 81 files survive), and
   only the needed columns are transferred — single-digit GB, not 17 GB.
   Filters: `country='US'`, `date_closed IS NULL`, non-null finite lat/lon,
   non-empty name, and a keyword→group table over `fsq_category_labels`
   (first match wins): 7 rest/truckstop (`truck stop`, `rest area`) → 0 fuel
   (`fuel station`, `electric vehicle charging`…) → 4 medical (`hospital`,
   `urgent care`, `pharmacy`, `drugstore`; vets excluded) → 3 hotel
   (`> lodging`, `hotel`/`motel`; hotel bars excluded) → 6 transit (rail /
   metro / tram / bus stations, marine terminals, airports-proper — gates,
   lounges, taxi stands, bus stops excluded) → 1 food (`dining and drinking`)
   → 2 stores (`retail`) → 5 tourist (`arts and entertainment`, `landmarks
   and outdoors`; towns/municipalities excluded). Region is normalized to a
   2-letter state code (full names mapped; unresolvable rows dropped).
   Output: `data/reference/fsq_places_us.tsv` (gitignored), headerless,
   columns: `group lat lon name street city region postcode website tel
   category_label`.
2. **Shard build** (`places-shard`, pure-std Rust, zero crates —
   `rust/flows-train/src/bin/places-shard.rs`): TSV →
   `data/places/<XX>.fps` per state plus `data/places/index.json`
   (per-state record counts + byte sizes). Both gitignored (regenerable).

### `.fps` v1 format ("FPS1", little-endian)

| Offset | Field |
|---|---|
| 0..4 | magic `FPS1` |
| 4..8 | version u32 (=1) |
| 8..12 | record count u32 |
| 12..20 | grid-index offset u64 (absolute) |
| 20..28 | fnv1a-64 body hash u64 (bytes 32..end; corrupt shard = refused) |
| 28..32 | grid cell count u32 |
| 32.. | records sorted by (0.2° cell key, name): `lat f32, lon f32, group u8, flags u8`, then u16-length-prefixed UTF-8 `name, street, city, website, tel`, then `postcode u32` (0=none) |
| grid off.. | grid index: `(cellKey i64, startRecord u32, count u32)` sorted by key for binary search |

Cell key: `lat5=floor(lat*5)`, `lon5=floor(lon*5)`,
`cellKey=(lat5+9000)*100000+(lon5+18000)`. Groups: 0=fuel 1=food 2=stores
3=hotel 4=medical 5=tourist 6=transit 7=rest/truckstop. Unit tests pin
round-trip, grid-lookup-vs-brute-force equality, hash rejection of
corruption, and truncation safety at every byte offset.

### Attribution (Apache 2.0 NOTICE — required)

Foursquare's NOTICE must be preserved wherever the shards ship.
`data/places/ATTRIBUTION.txt` (tracked in git, everything else in
`data/places/` is ignored) carries the upstream NOTICE plus FLOWS's
modification statement — **bundle it with the shards in the app**, and any
About/legal screen listing data sources should credit: *"Place data:
Foursquare OS Places, © Foursquare Labs, Inc., Apache License 2.0."*
