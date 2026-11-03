#!/usr/bin/env python3
"""Firewall Map+ bridge for the Omarchy bar widget.

Logs in to OPNsense with the credentials in the state file, then polls
/api/firewallmap/flow/summary and prints one compact JSON document per line
on stdout. The widget reads those lines; nothing else is written.

The login form uses a randomly named CSRF hidden field, so it is discovered
from the page on every login. TLS verification is off because an OPNsense GUI
normally uses its own self-signed certificate.
"""

import argparse
import html
import http.cookiejar
import ipaddress
import json
import math
import os
import queue
import re
import select
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import urllib.error

HIDDEN = re.compile(rb'<input type="hidden" name="([^"]+)" value="([^"]*)"')
LOGIN_MARKER = b'id="usernamefld"'
USER_AGENT = "Omarchy Firewall Map+ widget"
CSRF = re.compile(rb'setRequestHeader\(\s*[\"\']X-CSRFToken[\"\']\s*,\s*[\"\']([^\"\']+)', re.I)
RULE_PREFIX = "Omarchy Firewall Map+: block "
MAX_RESPONSE = 8 * 1024 * 1024
OUTPUT_LOCK = threading.Lock()


def read_response(response):
    raw = response.read(MAX_RESPONSE + 1)
    if len(raw) > MAX_RESPONSE:
        raise BridgeError("Firewall response is too large")
    return raw


class BridgeError(Exception):
    pass


class Bridge:
    def __init__(self, base, credentials, blocks_min, hostnames=True):
        self.base = base.rstrip("/")
        self.credentials_path = credentials
        self.blocks_min = max(1, min(100, int(blocks_min)))
        self.jar = http.cookiejar.CookieJar()
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar),
            urllib.request.HTTPSHandler(context=context),
        )
        self.username = ""
        self.password = ""
        self.credentials_mtime = None
        self.logged_in = False
        self.csrf = ""
        self.hostnames = hostnames
        self.load_credentials(force=True)

    # -- credentials -------------------------------------------------------

    def load_credentials(self, force=False):
        try:
            mtime = os.stat(self.credentials_path).st_mtime_ns
        except OSError:
            mtime = None
        if not force and mtime == self.credentials_mtime:
            return False
        self.credentials_mtime = mtime
        try:
            with open(self.credentials_path, encoding="utf-8") as handle:
                document = json.load(handle)
        except (OSError, ValueError) as error:
            raise BridgeError("Cannot read credentials: %s" % error)
        username = str(document.get("username") or "")
        password = str(document.get("password") or "")
        changed = username != self.username or password != self.password
        self.username, self.password = username, password
        if changed:
            self.logged_in = False
        return changed

    # -- http --------------------------------------------------------------

    def request(self, path, data=None, headers=None):
        request = urllib.request.Request(
            self.base + path,
            data=data,
            headers={"User-Agent": USER_AGENT, "Accept": "application/json",
                     "Cache-Control": "no-cache", **(headers or {})},
        )
        return self.opener.open(request, timeout=8)

    def login(self):
        if not self.username:
            raise BridgeError("No username configured")
        self.jar.clear()
        self.csrf = ""
        with self.request("/") as response:
            page = read_response(response)
        match = HIDDEN.search(page)
        if not match:
            raise BridgeError("Login page changed: no form token")
        fields = {
            match.group(1).decode(): match.group(2).decode(),
            "usernamefld": self.username,
            "passwordfld": self.password,
            "login": "1",
        }
        body = urllib.parse.urlencode(fields).encode()
        with self.request("/", body) as response:
            page = read_response(response)
        self.logged_in = LOGIN_MARKER not in page
        if not self.logged_in:
            raise BridgeError("Login failed: wrong username or password")

    def summary(self):
        path = "/api/firewallmap/flow/summary?blocks_min=%d&hostnames=%d" % (self.blocks_min, self.hostnames)
        with self.request(path) as response:
            raw = read_response(response)
        try:
            document = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            raise BridgeError("OPNsense returned a login page, not JSON")
        if not isinstance(document, dict):
            raise BridgeError("Unexpected firewall map response")
        return document

    def api(self, path, payload=None):
        """Session-authenticated JSON API. Mutations are never blindly retried."""
        if not self.logged_in:
            self.login()
        if payload is not None and not self.csrf:
            with self.request("/ui/firewallmap") as response:
                match = CSRF.search(read_response(response))
            if not match:
                raise BridgeError("Cannot read the firewall's CSRF token; sign in again")
            self.csrf = html.unescape(match.group(1).decode())
        headers = {}
        data = None
        if payload is not None:
            headers = {"Content-Type": "application/json", "X-CSRFToken": self.csrf}
            data = json.dumps(payload).encode()
        try:
            with self.request(path, data, headers) as response:
                result = json.loads(read_response(response))
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                self.logged_in = False
                self.csrf = ""
            raise BridgeError("Firewall API refused the request (HTTP %d)" % error.code) from error
        except ValueError as error:
            self.logged_in = False
            raise BridgeError("Firewall returned a login page or invalid API response") from error
        if not isinstance(result, dict):
            raise BridgeError("Unexpected firewall API response")
        if result.get("errorMessage"):
            raise BridgeError(str(result["errorMessage"])[:500])
        return result

    def managed_rules(self):
        result = self.api("/api/firewall/filter/search_rule", {"current": 1, "rowCount": -1,
                          "searchPhrase": RULE_PREFIX})
        if not isinstance(result.get("rows"), list):
            raise BridgeError("Firewall rule API unavailable; host blocking requires the filter API")
        rules = []
        for row in result["rows"]:
            if not isinstance(row, dict) or not row.get("uuid"):
                continue
            description = str(row.get("description", ""))
            if not description.startswith(RULE_PREFIX):
                continue
            try:
                address = str(ipaddress.ip_address(description[len(RULE_PREFIX):]))
            except ValueError:
                continue
            source, dest = row.get("source_net"), row.get("destination_net")
            # Only manage our exact single-address rules, never another rule
            # that happens to match a search phrase or has been repurposed.
            if (row.get("action") == "block" and row.get("quick") == "1"
                    and not row.get("interface") and row.get("direction") == "any"
                    and row.get("source_not", "0") == "0" and row.get("destination_not", "0") == "0"
                    and row.get("protocol", "any") == "any"
                    and not row.get("source_port") and not row.get("destination_port")
                    and (source, dest) in ((address, "any"), ("any", address))):
                rules.append({**row, "ip": address})
        return rules

    @staticmethod
    def blocked_hosts(rules):
        groups = {}
        for rule in rules:
            entry = groups.setdefault(rule["ip"], {"ip": rule["ip"], "directions": set()})
            if str(rule.get("enabled")) == "1":
                entry["directions"].add("source" if rule["source_net"] == rule["ip"] else "destination")
        return [{"ip": ip, "complete": len(entry["directions"]) == 2}
                for ip, entry in sorted(groups.items())]

    def apply_rules(self):
        result = self.api("/api/firewall/filter/apply", {})
        if str(result.get("status", "")).strip().lower() not in ("ok", "done"):
            raise BridgeError("Rules saved but firewall apply failed: " + str(result)[:300])

    def change_host(self, address, block, summary):
        address = validate_host(address, self.base, summary)
        rules = [rule for rule in self.managed_rules() if rule["ip"] == address]
        if not block:
            for rule in rules:
                result = self.api("/api/firewall/filter/del_rule/" + urllib.parse.quote(rule["uuid"], safe=""), {})
                if result.get("result") != "deleted":
                    raise BridgeError("Cannot remove the block rule: " + str(result)[:300])
            self.apply_rules()
            return address + " unblocked"
        created = []
        reenabled = []
        try:
            for field in ("source_net", "destination_net"):
                existing = next((rule for rule in rules if rule.get(field) == address), None)
                if existing:
                    if str(existing.get("enabled")) != "1":
                        result = self.api("/api/firewall/filter/set_rule/" + urllib.parse.quote(existing["uuid"], safe=""),
                                          {"rule": {"enabled": "1"}})
                        if result.get("result") != "saved":
                            raise BridgeError("Cannot enable the block rule")
                        reenabled.append(existing["uuid"])
                    continue
                rule = {"enabled": "1", "action": "block", "quick": "1", "interface": "",
                        "direction": "any", "ipprotocol": "inet6" if ":" in address else "inet",
                        "protocol": "any", "sequence": "1", "log": "1", "source_net": "any",
                        "destination_net": "any", "description": RULE_PREFIX + address}
                rule[field] = address
                result = self.api("/api/firewall/filter/add_rule", {"rule": rule})
                if result.get("result") != "saved" or not result.get("uuid"):
                    raise BridgeError("Cannot save the block rule: " + str(result.get("validations", result))[:300])
                created.append(result["uuid"])
            self.apply_rules()
        except Exception:
            # Roll back only rules added by this operation. If a response was
            # lost, the next read exposes any remaining partial block.
            for uuid in created:
                try:
                    self.api("/api/firewall/filter/del_rule/" + urllib.parse.quote(uuid, safe=""), {})
                except Exception:
                    pass
            for uuid in reenabled:
                try:
                    self.api("/api/firewall/filter/set_rule/" + urllib.parse.quote(uuid, safe=""),
                             {"rule": {"enabled": "0"}})
                except Exception:
                    pass
            if created or reenabled:
                try:
                    self.apply_rules()
                except Exception:
                    pass
            raise
        try:
            result = self.api("/api/diagnostics/firewall/kill_states", {"filter": address})
            if result.get("result") != "ok":
                raise BridgeError("State removal refused")
        except Exception:
            return address + " blocked; existing connections may continue until they expire"
        return address + " blocked; existing connections closed"

    # -- loop --------------------------------------------------------------

    def poll(self):
        if not self.logged_in:
            self.login()
        try:
            return self.summary()
        except (BridgeError, urllib.error.HTTPError):
            # Session may have expired: authenticate once more.
            self.logged_in = False
            self.login()
            return self.summary()


def validate_host(address, base, summary):
    try:
        ip = ipaddress.ip_address(str(address))
    except ValueError as error:
        raise BridgeError("Select a single IPv4 or IPv6 address") from error
    if ip.is_unspecified or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved:
        raise BridgeError("This address cannot be blocked from the widget")
    protected = {str(location.get("id")) for location in (summary or {}).get("locations", [])
                 if location.get("local") is True}
    protected.add(urllib.parse.urlsplit(base).hostname)
    try:
        interfaces = json.loads(subprocess.check_output(["ip", "-j", "address", "show"], timeout=2))
        protected.update(info["local"] for interface in interfaces for info in interface.get("addr_info", []))
    except (OSError, ValueError, subprocess.SubprocessError):
        raise BridgeError("Cannot verify this workstation's addresses; host blocking is unavailable")
    normalized = set()
    for value in protected:
        try:
            normalized.add(str(ipaddress.ip_address(value)))
        except ValueError:
            pass
    if str(ip) in normalized:
        raise BridgeError("Cannot block the firewall or this workstation")
    return str(ip)


FLOW_FIELDS = ("origin", "dest", "rate", "rate_in", "rate_out", "activity", "services",
               "service_ports", "inside", "initiated", "threat", "lists", "ids", "age",
               "transferred", "rule", "presence", "egress")
LOCATION_FIELDS = ("id", "name", "city", "region", "country", "country_code", "lat", "lon",
                   "local", "asn", "as_org", "home")
BLOCK_FIELDS = ("source", "target", "hits", "hits_per_minute", "window_minutes", "threat",
                "services", "ports", "port_count", "country", "country_code", "city", "as_org",
                "rule", "interface", "seconds", "lat", "lon")


def pick(item, fields):
    if not isinstance(item, dict):
        return {}
    return {name: item[name] for name in fields if name in item}


def compact(document):
    """Keep only what the widget draws, so a 2 s poll stays small on the wire."""
    if not isinstance(document, dict):
        return {"status": "bridge_error", "error": "Unexpected response"}
    result = {
        "status": document.get("status", "ok"),
        "reason": document.get("reason"),
        "sampled_at": document.get("sampled_at"),
        "age": document.get("age"),
        "interval": document.get("interval"),
        "provider": document.get("provider"),
        "tracked_flows": document.get("tracked_flows"),
        "tracked_flows_estimated": document.get("tracked_flows_estimated"),
        "flows": [pick(item, FLOW_FIELDS) for item in document.get("flows") or []],
        "locations": [pick(item, LOCATION_FIELDS) for item in document.get("locations") or []],
        "blocks": [pick(item, BLOCK_FIELDS) for item in document.get("blocks") or []],
        "blocks_below": document.get("blocks_below", 0),
        "ids_flows": document.get("ids_flows") or [],
        "alerts": len(document.get("alerts") or []),
        "interfaces": document.get("interfaces") or [],
        "threat_lists": document.get("threat_lists") or [],
        "crowdsec": document.get("crowdsec") or {},
        "hostnames": document.get("hostnames") or {},
    }
    for flow in result["flows"]:
        if isinstance(flow.get("inside"), list):
            flow["inside"] = [pick(host, ("ip", "name", "interface")) for host in flow["inside"]]
    return result


def emit(payload):
    with OUTPUT_LOCK:
        sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
        sys.stdout.flush()


def next_delay(document, requested):
    """Sleep just past the collector's next sample, not a fixed period.

    The service samples PF every couple of seconds and publishes the age of
    its latest sample. Sleeping a full period after a response usually lands
    just before the next sample, so the widget would always show 1.5-2 s old
    data. Following ``age`` keeps each update as fresh as the collector allows
    without polling faster than the requested interval.
    """
    try:
        age = float(document.get("age"))
        server_interval = float(document.get("interval"))
    except (TypeError, ValueError):
        return requested
    if not math.isfinite(server_interval) or not math.isfinite(age) or server_interval <= 0 or age < 0:
        return requested
    # Age describes the sample at response time; do not subtract the HTTP
    # request duration again when sleeping after this response.
    remaining = server_interval - (age % server_interval) + 0.08
    return max(0.25, min(requested, remaining))


class Commands:
    """Bounded line reader; never hide queued commands in stdio buffering."""
    def __init__(self, fd):
        self.fd = fd
        self.buffer = b""
        self.closed = False

    def read(self, timeout):
        if b"\n" not in self.buffer and not self.closed:
            ready, _, _ = select.select([self.fd], [], [], timeout)
            if ready:
                chunk = os.read(self.fd, 4096)
                self.closed = not chunk
                self.buffer += chunk
        elif self.closed and not self.buffer and timeout:
            time.sleep(timeout)
        if b"\n" not in self.buffer:
            if len(self.buffer) > 4096 or self.closed:
                self.buffer = b""
            return None
        line, self.buffer = self.buffer.split(b"\n", 1)
        try:
            command = json.loads(line) if len(line) <= 4096 else {}
        except (ValueError, UnicodeDecodeError):
            return {}
        return command if isinstance(command, dict) else {}


class HostActions(threading.Thread):
    """Keep slow rule/CSRF requests out of the traffic sampling loop.

    This worker owns a separate HTTP session. Only it touches its cookie jar
    or changes rules; samples and command results share a locked JSON writer.
    """
    def __init__(self, base, credentials, blocks_min, hostnames):
        super().__init__(name="firewall-host-actions", daemon=True)
        self.bridge_args = (base, credentials, blocks_min, hostnames)
        self.commands = queue.Queue(maxsize=4)
        self.summary = {}
        self.refresh_requested = threading.Event()
        self.next_hosts = 0
        self.bridge = None

    def submit(self, command):
        try:
            self.commands.put_nowait(command)
            return True
        except queue.Full:
            return False

    def check_hosts(self):
        try:
            emit({"type": "hosts", "hosts": self.bridge.blocked_hosts(self.bridge.managed_rules())})
        except Exception as error:
            emit({"type": "hosts", "error": str(error)[:500]})
        self.next_hosts = time.monotonic() + 30

    def execute(self, command):
        """One serialized host command; also used by the offline tests."""
        action = command.get("action")
        if action in ("block", "unblock"):
            try:
                message = self.bridge.change_host(command.get("ip"), action == "block", self.summary)
                emit({"type": "action", "ok": True, "message": message})
            except Exception as error:
                emit({"type": "action", "ok": False, "message": str(error)[:500]})
            self.refresh_requested.set()
        self.check_hosts()

    def run(self):
        while True:
            try:
                command = self.commands.get(timeout=max(0, self.next_hosts - time.monotonic()))
            except queue.Empty:
                command = {"action": "hosts"}
            try:
                if self.bridge is None:
                    self.bridge = Bridge(*self.bridge_args)
                else:
                    self.bridge.load_credentials()
                self.execute(command)
            except Exception as error:
                event = {"type": "action", "ok": False, "message": str(error)[:500]} if command.get("action") in ("block", "unblock") \
                    else {"type": "hosts", "error": str(error)[:500]}
                emit(event)
                self.next_hosts = time.monotonic() + 30


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--credentials", required=True)
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--blocks-min", type=int, default=2)
    parser.add_argument("--no-hostnames", action="store_true")
    args = parser.parse_args()

    interval = max(1.0, min(30.0, args.interval))
    bridge = Bridge(args.base, args.credentials, args.blocks_min, not args.no_hostnames)
    host_actions = HostActions(args.base, args.credentials, args.blocks_min, not args.no_hostnames)
    host_actions.start()
    next_poll = 0
    commands = Commands(sys.stdin.fileno())

    while True:
        if host_actions.refresh_requested.is_set():
            host_actions.refresh_requested.clear()
            next_poll = 0
        remaining = max(0, next_poll - time.monotonic())
        command = commands.read(min(remaining, 0.25))
        if command is not None:
            try:
                action = command.get("action")
                if action == "refresh":
                    next_poll = 0
                elif action in ("hosts", "block", "unblock"):
                    if not host_actions.submit(command):
                        raise BridgeError("A host operation is already queued; try again shortly")
                else:
                    raise BridgeError("Unknown widget command")
            except Exception as error:
                emit({"type": "action", "ok": False, "message": str(error)[:500]})
        if time.monotonic() < next_poll:
            continue
        delay = interval
        try:
            bridge.load_credentials()
            document = compact(bridge.poll())
            host_actions.summary = document
            # Every successful request is a heartbeat, even for an unchanged
            # sample or collectors that omit sampled_at. QML avoids redrawing
            # the map for unchanged data while keeping freshness accurate.
            emit(document)
            delay = next_delay(document, interval)
        except BridgeError as error:
            emit({"status": "bridge_error", "error": str(error)})
        except Exception as error:  # network, TLS, timeouts
            emit({"status": "bridge_error", "error": "%s: %s" % (type(error).__name__, error)})
        next_poll = time.monotonic() + max(0.25, delay)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
