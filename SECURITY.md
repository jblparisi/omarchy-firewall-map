# Security and data handling

This plugin runs as your normal desktop user inside Omarchy's Quickshell shell.
It starts Python helpers, reads/writes its credential file and calls the local
`ip` command to avoid blocking this workstation. There are no install hooks,
sudo rules, privileged local services or remote code downloads.

The enabled bridge polls the OPNsense address you configure, even while the
panel is closed. Authentication uses an OPNsense GUI session and its CSRF token.
Only explicit row actions change firewall rules or close states. Disable the
plugin to stop polling.

Passwords are written over stdin, stored atomically in a mode-0600 file and are
not included in shell.json or helper command-line arguments. The widget needs
the plaintext password to establish a GUI session; the file is not encrypted.
Do not commit that file or attach real traffic/credentials to public issues.

TLS certificate verification is **disabled** in the current bridge because
self-signed certificates are common on OPNsense. HTTPS still carries the
connection, but this does not authenticate the server certificate. Connect over
a trusted management network or VPN. Certificate verification is a known area
for future improvement.

GeoIP geometry is bundled locally. The widget itself has no map-tile service,
analytics, hosted traffic collector or telemetry. OPNsense's upstream Firewall
Map+ module may access its configured GeoIP/threat providers independently.

Untrusted hostnames and API messages are displayed as plain text. Shared
tooltips neutralize markup-shaped values. Responses are bounded by the bridge.
Persistent rule operations apply only to this widget's exact matching rules;
unrelated or repurposed rules are left alone.

If reporting a bug publicly, replace real usernames, IP addresses, hostnames
and traffic details with synthetic examples. For a vulnerability, use GitHub's
private vulnerability reporting on this repository when available.
