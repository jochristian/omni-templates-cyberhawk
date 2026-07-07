# GeoPulse ← Home Assistant GPS source

Forwards Home Assistant device-tracker updates (companion app, router
tracking, …) to GeoPulse's native Home Assistant endpoint
(`https://geopulse.cyberhawk.no/api/homeassistant`, Bearer-token auth).
The endpoint sits under `/api`, so it rides the existing frontend→backend
proxy path — no cluster changes needed.

## 1. Create the source in GeoPulse

1. Generate a token locally: `openssl rand -hex 32`
2. GeoPulse UI → **Settings → Location Sources → Add New Source → Home
   Assistant**, paste the token, **Save**.

## 2. Home Assistant: `secrets.yaml`

The whole header value goes in the secret, including the `Bearer ` prefix:

```yaml
geopulse_auth: "Bearer <the token from step 1>"
```

## 3. Home Assistant: `configuration.yaml`

One parameterized `rest_command` serves any number of trackers:

```yaml
rest_command:
  geopulse_send_gps:
    url: "https://geopulse.cyberhawk.no/api/homeassistant"
    method: POST
    headers:
      content-type: "application/json"
      Authorization: !secret geopulse_auth
    payload: >
      {
        "device_id": "{{ device_id }}",
        "timestamp": "{{ now().isoformat() }}",
        "location": {
          "latitude": {{ latitude }},
          "longitude": {{ longitude }},
          "accuracy": {{ accuracy }},
          "altitude": {{ altitude }},
          "speed": {{ speed }}
        },
        "battery": {
          "level": {{ battery }}
        }
      }
```

## 4. Home Assistant: `automations.yaml`

Find the tracker entity ID under **Developer Tools → States**, filter
`device_tracker.` (the companion-app tracker carries `latitude`/`longitude`
attributes). Replace `device_tracker.YOUR_PHONE` below; add one trigger
entry per additional device — the action is generic.

Entity-suffix gotcha (hit during setup): after a phone re-registration the
tracker can be suffixed (`device_tracker.pixel_10_pro_xl_3`) while the
notify service and battery sensor keep the base name
(`notify.mobile_app_pixel_10_pro_xl`, `sensor.pixel_10_pro_xl_battery_level`).
Verify each name individually; the live tracker is the one whose
`last_updated` moves.

Use ONE trigger without `attribute:` — it fires once per tracker update.
Separate latitude/longitude attribute triggers BOTH fire on the same
report, double-posting every point (observed live).

```yaml
- alias: Send GPS data to GeoPulse
  id: geopulse_gps_forward
  mode: queued
  max: 10
  trigger:
    - platform: state
      entity_id: device_tracker.YOUR_PHONE
  condition:
    # Skip updates without a GPS fix — a None lat/lon would render invalid JSON.
    - condition: template
      value_template: >
        {{ state_attr(trigger.entity_id, 'latitude') is not none
           and state_attr(trigger.entity_id, 'longitude') is not none }}
  action:
    - service: rest_command.geopulse_send_gps
      data:
        device_id: "{{ trigger.entity_id.split('.')[1] }}"
        latitude: "{{ state_attr(trigger.entity_id, 'latitude') }}"
        longitude: "{{ state_attr(trigger.entity_id, 'longitude') }}"
        accuracy: "{{ state_attr(trigger.entity_id, 'gps_accuracy') | default(0, true) }}"
        altitude: "{{ state_attr(trigger.entity_id, 'altitude') | default(0, true) }}"
        speed: "{{ state_attr(trigger.entity_id, 'speed') | default(0, true) }}"
        # battery_level is usually NOT a tracker attribute — it comes from the
        # separate battery sensor. int(0) guards the "unknown" string, which
        # would otherwise render invalid JSON.
        battery: >-
          {{ state_attr(trigger.entity_id, 'battery_level')
             | default(states('sensor.YOUR_PHONE_battery_level'), true)
             | int(0) }}
```

**Debugging silent failures:** the backend logs
`Received payload for home assistant: …` at INFO for every request that
parses. A 400 with no such log line = the JSON never parsed — almost always
an empty/missing `data:` block in the automation (undefined variables render
as empty strings → `"latitude": ,`). The GUI editor strips `data:` when the
action is re-picked in visual mode — always edit/save this automation in
YAML mode. The frontend pod's nginx access log shows every POST + status.

Restart Home Assistant (or reload YAML: rest_command needs **Developer Tools
→ YAML → Restart** the first time).

### GUI-editor alternative to step 4

Instead of editing `automations.yaml`, paste this in **Settings →
Automations & scenes → Create automation → Create new automation → ⋮ →
Edit in YAML** (modern `triggers`/`actions` syntax; the GUI stores it with
its own `id:` — don't ALSO add the hand-written variant above, that would
double-post every point). The `rest_command` in `configuration.yaml` is
still required first — the GUI cannot create it.

```yaml
alias: Send GPS data to GeoPulse
description: Forward device_tracker GPS updates to GeoPulse
mode: queued
max: 10
triggers:
  - trigger: state
    entity_id: device_tracker.YOUR_PHONE
conditions:
  - condition: template
    value_template: >
      {{ state_attr(trigger.entity_id, 'latitude') is not none
         and state_attr(trigger.entity_id, 'longitude') is not none }}
actions:
  - action: rest_command.geopulse_send_gps
    data:
      device_id: "{{ trigger.entity_id.split('.')[1] }}"
      latitude: "{{ state_attr(trigger.entity_id, 'latitude') }}"
      longitude: "{{ state_attr(trigger.entity_id, 'longitude') }}"
      accuracy: "{{ state_attr(trigger.entity_id, 'gps_accuracy') | default(0, true) }}"
      altitude: "{{ state_attr(trigger.entity_id, 'altitude') | default(0, true) }}"
      speed: "{{ state_attr(trigger.entity_id, 'speed') | default(0, true) }}"
      battery: >-
        {{ state_attr(trigger.entity_id, 'battery_level')
           | default(states('sensor.YOUR_PHONE_battery_level'), true)
           | int(0) }}
```

Force a location report for testing with
`notify.mobile_app_YOUR_PHONE` (base name, no suffix!) and
`message: request_location_update` — or simply open the app on the phone,
which pushes a report immediately.

## 5. Verify

- Trigger a location update (toggle location on the phone, or Developer
  Tools → Actions → `rest_command.geopulse_send_gps` with test data).
- The point appears in GeoPulse → map/timeline within seconds.
- On failure, check HA logs for `rest_command` errors (401 = token mismatch
  with the GeoPulse source; 400 = payload rendered invalid JSON).

## 6. Companion-app tracking settings (Android)

The default "balanced" reporting (one point every ~4–15 min, on movement)
is enough for GeoPulse's stay/trip detection — a 1.8 km walk was classified
correctly at that density. What matters most is stopping Android from
suppressing the reports:

- **App info → Permissions → Location → "Allow all the time"** + **"Use
  precise location"**. With "Only while using", background reports fall back
  to coarse network fixes (~100 m accuracy).
- **App info → Battery → Unrestricted.** Pixels defer background work
  otherwise; this alone causes 15+ minute gaps.

Sensor options live in the HA app → **Settings → Companion app → Manage
sensors → Location sensors → Background location** (the Companion app entry
only exists on the phone; enable the sensor first or the options stay
hidden):

- **Minimum accuracy:** leave at 200 m — GeoPulse copes with the occasional
  coarse point, and filtering harder just creates gaps.
- **High accuracy mode:** OFF by default (deliberate — foreground service +
  real battery drain). For dense tracks on demand, toggle it from an HA
  automation with the `command_high_accuracy_mode` notification command
  instead of leaving it on:

```yaml
alias: GeoPulse high accuracy when away
mode: single
triggers:
  - trigger: state
    entity_id: device_tracker.YOUR_PHONE
    from: home
    id: left
  - trigger: state
    entity_id: device_tracker.YOUR_PHONE
    to: home
    id: arrived
actions:
  - choose:
      - conditions:
          - condition: trigger
            id: left
        sequence:
          - action: notify.mobile_app_YOUR_PHONE   # base name, no suffix!
            data:
              message: command_high_accuracy_mode
              data:
                command: turn_on
      - conditions:
          - condition: trigger
            id: arrived
        sequence:
          - action: notify.mobile_app_YOUR_PHONE
            data:
              message: command_high_accuracy_mode
              data:
                command: turn_off
```

Set **High accuracy mode update interval** to 30–60 s in the sensor settings
so the command has effect. Same YAML-mode editing caveat as section 4 — the
visual editor strips the nested `data:` blocks.

## Notes

- Update cadence = whatever the companion app reports; see section 6 for
  tuning. GeoPulse's stay/trip detection works better with more points, but
  the balanced default is sufficient.
- The upstream reference for the payload shape is
  `docs-website/docs/user-guide/gps-sources/home_assistant.md` in the
  GeoPulse repo; fields verified against `HomeAssistantGpsData` (device_id,
  timestamp, location{latitude,longitude,accuracy,altitude,speed},
  battery{level}).
