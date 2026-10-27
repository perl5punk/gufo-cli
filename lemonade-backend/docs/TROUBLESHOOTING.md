# Troubleshooting

Real messages seen while building and running this, with causes and fixes.

## First, look in the right place

```bash
gufo-lemonade status                    # bridge + Lemonade view, one shot
gufo-lemonade doctor                    # prerequisite checks
journalctl --user -u gufo-lemonade.service -f          # bridge log
podman ps --filter name=gufo-                          # engine containers
gufo logs gufo-qwen3-8-27b-ud-q4-k-m --no-follow       # engine log (model load, tps)
curl -s localhost:13399/health | jq                     # bridge, no auth
curl -s -H "Authorization: Bearer $(jq -r .api_key ~/.config/gufo-lemonade/config.json)" \
     localhost:13399/gufo/status | jq .registration     # last registration attempt
curl -s localhost:13305/v1/models | jq -r '.data[].id | select(startswith("gufo."))'
lemonade cloud list                                     # provider + key + models_discovered
```

Request path: **client → lemond :13305 → bridge :13399 → container :13400+**.
An error's `type` tells you which hop produced it: `network_error`/`backend_error`
= Lemonade→bridge, `gufo_bridge_error` = bridge, anything else = Gufo container.

## `gufo.*` models are missing from Lemonade

| Symptom | Cause | Fix |
|---|---|---|
| `lemonade cloud list` shows nothing | provider never installed, or `lemond` was reset | `./install.sh` again, or `gufo-lemonade refresh` |
| provider listed, `models_discovered=0` | bridge down, wrong `base_url`, or catalog empty | `systemctl --user start gufo-lemonade`, `gufo-lemonade models` |
| provider listed, `runtime_key_set=no` | lemond restarted and the CLI-installed key is memory-only | start the bridge (it re-registers itself) or `gufo-lemonade refresh` |
| nothing in `journalctl`, service `inactive` | autostart not enabled / no login session | `systemctl --user enable --now gufo-lemonade`, `loginctl enable-linger $USER` |
| `models_discovered` lags behind disk | new/removed GGUF, rescan interval | `gufo-lemonade scan` (or wait up to `scan_interval_seconds`) |

## `Network error: CURL error: Could not connect to server`

From Lemonade — the bridge is not listening. Lemonade keeps advertising the
models it cached, so this is what you get instead of a reply.

```bash
systemctl --user status gufo-lemonade.service
journalctl --user -u gufo-lemonade.service -n 50
```

Common reasons: the service was never started; the port is taken (change `port`
in the config, restart, then `lemonade cloud install gufo --base-url
http://127.0.0.1:<newport>/v1 --api-key <key> --allow-insecure-http`); the bridge
crashed on a config error — `python3 -c "import json,os;json.load(open
(os.path.expanduser('~/.config/gufo-lemonade/config.json')))"` to check JSON
syntax (a malformed file makes the bridge fall back to defaults, but a
non-writable `models_dirs` entry will show up as a scan error).

## `401 missing or invalid API key`

The bridge now requires the key Lemonade was told to send (`api_key` in the
config; `/health` is the only unauthenticated path).

- You changed `api_key` in the config → restart the bridge **and** re-register:
  `lemonade cloud install gufo --base-url http://127.0.0.1:13399/v1 --api-key <new-key> --allow-insecure-http`
- A `LEMONADE_GUFO_API_KEY` in `/etc/default/lemond` disagrees with the config →
  make them match, `sudo systemctl restart lemond`.
- You are curling the bridge directly → add
  `-H "Authorization: Bearer $(jq -r .api_key ~/.config/gufo-lemonade/config.json)"`.

## Lemonade's load / unload / stop buttons do nothing

Expected. For a `cloud` provider, `lemonade load` only records the model as
loaded (its server has no subprocess to start), and `unload` nothing to kill.
The bridge owns the containers:

```bash
gufo-lemonade load MODEL      # start the container
gufo-lemonade unload MODEL    # stop it  ('all' for every model)
gufo status                    # the gufo CLI's own view
```

For an interactive session use `lemonade chat gufo.<model>` (terminal) or
`lemonade run gufo.<model>` (web UI) — `lemonade run` takes a model only, no
prompt argument.

## `503 ... is still loading in container gufo-...; retry in a minute`

Working as intended: the first request started the container and the bridge
stopped waiting at `start_wait_seconds`. The load continues in the background —
ask again. If you want it warm instead of waiting:

```bash
gufo-lemonade load Qwen3.8-27B-UD-Q4_K_M      # blocks until ready
journalctl --user -u gufo-lemonade.service | grep 'ready'
```

Lower `start_wait_seconds` if Lemonade gives up before this message arrives;
raise it if you would rather wait inside the request. `autostart` warms models at
bridge start.

## `502 gufo run failed: ...`

The engine refused to start. The message is Gufo's own, verbatim.

| Message | Meaning |
|---|---|
| `Unexpected Qwen layer kind at blk.0: expected Gated DeltaNet` | expected for GGUFs outside the families this `gufo-runtime` build carries `gfx1151` kernels for — Gufo targets Strix Halo and specific architectures. Not a bridge or Lemonade problem. Check `gufo diagnose` and the runtime release notes, and hide the file from the picker with `model_overrides: {"<id>": {"hidden": true}}` |
| `Error loading model ... out of memory` / container killed | no room in unified memory. `podman ps -a`, free a model (`gufo-lemonade unload all`), keep `max_loaded: 1`, or lower `ctx` |
| `Unable to find image ...` / registry timeout | podman cannot pull; `podman pull ghcr.io/gufo-org/toolboxes/gufo-runtime:latest` manually and retry |
| `no free port found from 13400` | port range exhausted or `ss` missing (iproute2) |
| `model failed to load (container left running: ...)` | read `gufo logs <container>`; the bridge also names it in the error |

After a failure the bridge waits `retry_backoff_seconds` (60 s) before trying the
same model again, so a burst of Lemonade retries cannot thrash the GPU. Force an
immediate retry with `gufo-lemonade load <model> --force` or clear it with
`gufo-lemonade unload <model>`.

## A model that is already running answers `model_not_found`

Each Gufo container serves the name baked into the GGUF (`general.name`, e.g.
`Qwen3.8 Flash Next`) while the bridge publishes a file-derived id
(`Qwen3.8-Flash-Next-UD-Q4_K_XL`). The bridge fixes this two ways: containers it
starts get `gufo run --served-name <published id>`, and proxied requests are
rewritten to whatever the container reports. If you see this:

- `gufo-lemonade status` — does the container show a `served_id` that differs
  from the id? If `use_served_names` is `false`, turn it back on and restart the
  bridge (existing containers still work via rewriting).
- You renamed the `.gguf` file while its container ran → the id changed, the
  container did not. `gufo-lemonade unload <new id>` then retry.
- In **streaming** replies the `model` field inside SSE chunks is whatever the
  container emitted (upstream behaviour); the non-streaming response carries the
  published id.

## The container starts but Lemonade times out

Loading a 100 GB checkpoint on Strix Halo takes minutes. Lemonade's cloud client
has its own timeout, so a cold model looks like a hang. Keep
`start_wait_seconds` *below* that timeout (the 503 above is far more useful than
a client-side timeout), and warm models with `load`/`autostart`.

## Streaming works directly but not through Lemonade

The bridge proxies SSE unchanged. If you put nginx/Caddy/Traefik in front of
Lemonade, disable buffering for the route
(`proxy_buffering off;`, `proxy_read_timeout` generous). Test the hops one at a
time:

```bash
curl -N localhost:13400/v1/chat/completions -d '{"model":"...","stream":true,...}'   # container
curl -N localhost:13399/v1/chat/completions -H "Authorization: Bearer ..." -d '...'  # bridge
curl -N localhost:13305/v1/chat/completions -d '{"model":"gufo. ...","stream":true}' # lemonade
```

## Memory: models keep getting evicted (or the box thrashes)

`max_loaded` is the knob: `1` (default) evicts the LRU container **before**
starting the next model — with 123 GB unified memory and a 111 GB checkpoint
that is the only safe policy. `0` disables eviction, `idle_timeout_min` releases
idle models. Watch it live:

```bash
watch -n5 'gufo-lemonade status | grep -E "loaded|GB"; free -g | head -2'
```

Eviction only ever stops containers the bridge started or adopted — never
anything else you run in podman.

## `systemctl --user` fails ("Failed to connect to bus")

The unit is a **user** service, so it needs your session bus — expected when
running from ssh, cron, or a container:

```bash
loginctl enable-linger $USER
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user status gufo-lemonade
```

Never move this to a system unit: it must run as you, because rootless podman
(and your `~/models`) belong to your UID. That is also why a native Lemonade
backend — which runs as the `lemonade` user with `ProtectHome=yes` — cannot drive
this setup (see [ANALYSIS.md](ANALYSIS.md)).

## Installing on a machine where `cloud` refuses the URL

`lemonade cloud install` rejects `http://` unless you pass
`--allow-insecure-http`; it also rejects an empty API key. `install.sh` passes
both. If Lemonade reports `insecure http provider requires --allow-insecure-http`
after a manual re-registration, add the flag.

## Reset to a known state

```bash
gufo-lemonade unload all                                   # stop engine containers
systemctl --user stop gufo-lemonade.service
lemonade cloud uninstall gufo                              # unregister
rm ~/.config/gufo-lemonade/config.json                     # back to defaults
./install.sh                                               # rebuild everything
```

Worst case, `./uninstall.sh --purge` removes the bridge, service, provider and
(optionally) the installed binaries, and `gufo` alone keeps working as before.
