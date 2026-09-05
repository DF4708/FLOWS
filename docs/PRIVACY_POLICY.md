<!--
  Copyright (c) 2026 David B. Foster. All rights reserved.
  Contact: wizeman555@gmail.com
  Unauthorized copying, distribution, modification, or use of this file, in
  whole or in part, is strictly prohibited without the express written
  permission of the copyright holder.
-->

# FLOWS Privacy Policy

_Effective: July 5, 2026_

FLOWS is a weather-aware navigation app for North America, developed by
David B. Foster (contact: wizeman555@gmail.com).

## What FLOWS collects — and where it stays

**FLOWS has no server of its own.** Everything below is processed on your
device and stored only on your device:

- **Location** — used for navigation, weather/risk overlays, nearby stops,
  and country-appropriate cost ratings. Never uploaded to us; coordinates
  are sent only to the data services that need them to answer a query
  (Apple Maps routing/search, NWS/ECCC/SMN weather, USGS elevation and
  earthquakes, NOAA fire data, OpenStreetMap Overpass, Open-Meteo, EPA
  fueleconomy.gov, RainViewer radar tiles — each per its own policy).
  Trucker mode's NOAA Weather Radio streams come from weatherusa.net's
  public relays (radio.weatherusa.net); no location or personal data is
  sent to that host — the app only downloads the audio stream.
- **Vehicle profile, trip settings, emergency contact** — stored in the
  app's local preferences on your device only.
- **Favorites (Home, Work, saved places)** — encrypted on your device under
  their own key, separate from the learned-data key below, so "Erase
  everything FLOWS has learned" leaves the addresses you typed in place.
  Earlier builds kept these in the app's preferences, which iOS includes
  in backups; on first launch of this build they are moved into encrypted
  storage and the old copy is removed.
- **Open-Meteo** supplies the air-quality and UV readings on the risk map.
  Their data is CC BY 4.0: weather data by Open-Meteo.com.
- **What FLOWS learns about your travel — ENCRYPTED ON YOUR DEVICE.** To
  make the app useful without asking you to retype what you do every day,
  FLOWS keeps a record of:
  - the destinations you plan, and when;
  - the places you pick from result lists, with the time of day, whether
    it was a weekday or weekend, and roughly where you set out from;
  - which route you chose when you were offered several, and what the
    alternatives were;
  - the trips you complete — start and end areas, week of year, and the
    weather risk actually encountered versus what was predicted;
  - how you drive: your typical speed and idling, and how your real
    arrival times compare to the estimate;
  - a trail of the roads you have actually driven, and the map data
    cached along the corridors you drive often, so those roads still
    work with no signal;
  - how long stretches of road actually take you at each hour, and how
    much fuel each one actually costs you.

  This is the most personal data in the app — over time it is a map of
  your life — so it is treated that way. **All of it is encrypted at rest
  (AES-GCM) with a key generated on your device, held in the device
  Keychain, marked device-only: it is never synced to iCloud and never
  included in a backup.** If your phone is lost, stolen, or resold, these
  files are unreadable without that key. They are decrypted only into
  memory, only while the app is using them, and are never uploaded — FLOWS
  has no server to upload them to.

  The risk model that learns from this is refined **on your device**; no
  training data and no learned model ever leaves it.

  Settings → **"What FLOWS has learned about you"** shows exactly what is
  stored and erases all of it in one press. Erasing also destroys the
  encryption key, so any copy that escaped stays unreadable.

  "All of it" is meant literally, and is now enforced rather than
  asserted: every file in this list is written through one store, and
  the erase button walks that same list. An earlier build failed this —
  the four items covering where you have physically driven were written
  as plain text and had no eraser at all, so the most sensitive data
  here outlived the button that promises otherwise. Anything a driver
  can be told is erased must be erased by code that cannot be
  forgotten when a new store is added.
- **Medical notes and connected-account secrets** — stored in the device
  Keychain (never synced, never included in backups). Medical notes appear
  only in the crash-report message YOU send.
- **Bluetooth tire/fuel data** — read from your own sensors/adapter,
  processed on device, never transmitted.
- **Connected-vehicle accounts (Smartcar or OEM)** — optional. OAuth tokens
  are stored on your device; vehicle data (fuel level, tire pressure) is
  fetched directly from that provider to your device under their privacy
  terms. FLOWS never sees your car-account password.
- **Optional API keys you provide** (e.g., Yelp) — stored locally, used
  only to query that provider for the data shown next to results.

## What FLOWS does not do

No accounts. No analytics. No advertising. No sale or sharing of personal
data. No background tracking beyond active navigation. No reading of
Apple Health / Medical ID.

## Crash assistance

If crash detection is enabled and an impact is sensed, the microphone is
used briefly (with iOS permission) to hear your reply. Calls and texts are
always initiated by you with a tap — the app cannot contact anyone
silently.

## Your controls

Every notification type, crash detection, Bluetooth scanning, and each
connected account can be turned off in Settings. Settings →
"What FLOWS has learned about you" lists everything the app has inferred
about your travel and erases it — along with its encryption key — in one
press. Deleting the app deletes all locally stored data.

## Changes

Updates to this policy ship with app updates and take effect on install.
