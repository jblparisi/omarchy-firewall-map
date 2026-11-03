# Development and verification

The repository root is an installable Omarchy plugin. `manifest.json` supplies
the permanent ID `jblparisi.firewall-map`, and declares one service and one bar
widget. The service is shared by every monitor's widget.

| File | Responsibility |
| --- | --- |
| `bridge.py` | OPNsense GUI login, bounded summary polling and explicit host actions |
| `credentials.py` | Atomic, mode-0600 credential storage from stdin |
| `Service.qml` | Bridge lifetime, heartbeat age, settings and credential state |
| `BarWidget.qml` | Bar icon and panel loading |
| `Panel.qml` | Counts, host lists, settings, map controls and row actions |
| `Map.qml` | Full-world fit, drag/wheel navigation, flow animation and picking |
| `Model.js` | Formatting, settings and flow/host aggregation |
| `World.js` | Simplified public-domain Natural Earth land geometry |

Run:

```bash
omarchy plugin validate .
python3 -m unittest discover -s tests -v
node tests/test_model.cjs
```

With Qt 6 Quick Test installed, the map interaction tests also run without a
desktop session. The test-only Commons fixtures supply fonts and colors:

```bash
QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=generic \
QT_QUICK_CONTROLS_STYLE=Basic QT_QUICK_BACKEND=software \
  /usr/lib/qt6/bin/qmltestrunner \
  -import tests/qml/imports -input tests/qml/tst_map.qml
```

The Python suite mocks the OPNsense API. It covers rule idempotence, rollback,
CSRF handling, session recovery, independent traffic/action sessions, protected
addresses and private credential storage. The JavaScript suite covers precise
host identity, threat filtering, co-located addresses, selections and markup.

Before releasing UI changes, verify these interactions in Omarchy:

1. Reopen the panel and settings without losing the world layer.
2. Confirm the whole world fits on a short display, including southern land.
3. Drag without triggering a host click or resetting the active list.
4. Zoom around the pointer and use Fit to restore the world.
5. Select hosts and connections after panning and zooming.
6. Click empty map space from Blocked, Threats and a selection to return to Flows.
7. Confirm there is exactly one Block/Unblock control per host row, with no
   selected-host popup or duplicate footer action.

QML rendering and pointer interactions were exercised with the Qt 6 test runner
before this release; the full-world map and controls were also checked on the
running desktop. Avoid accidentally using the Qt 5 `qmltestrunner` binary on a
machine where both versions are installed.

The repository screenshots are rendered with synthetic data and fictional
hostnames. Never use an uncropped desktop screenshot or real firewall sample as
a public preview. `preview.png` is the marketplace preview; `docs/images/` holds
the README gallery.
