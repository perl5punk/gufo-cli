# Can `gufo-cli` be a Lemonade backend?

Findings from reading the Lemonade Server source (v11.9.0) and running the two
integrations side by side. Bottom line:

> A *first-class* Lemonade backend must be C++ compiled into `lemond` — there is
> no plugin API, so `gufo-cli` cannot be one without a fork. A *functionally*
> first-class integration is available today: Lemonade's `cloud` recipe pointed
> at the `gufo-lemonade` bridge in this directory. That is what we ship.

---

## 1. What a Lemonade backend actually is

Three pieces, all resolved at compile time:

**Descriptor** — `src/cpp/include/lemon/backends/<name>/<name>.h`, a
`BackendDescriptor` of plain data:

```cpp
inline const BackendDescriptor descriptor = {
    /*recipe*/       "vllm",
    /*binary*/       "vllm-server",        // subprocess lemon launches
    /*slot_policy*/  SlotPolicy::Standard, // how it shares the accelerator
    /*dynamic_models*/ false,              // true = models supplied at runtime
    /*options*/      { {"vllm_args", "--vllm-args", "", "ARGS", ...} },
    /*support*/      { {"rocm", BackendTier::Experimental, BackendFormat::Python,
                        {"linux"}, {{"amd_gpu", {"gfx1151", ...}}}, "Strix Halo iGPU"} },
    /*supported_modes*/ {"chat"},
    /*required_checkpoints*/ {"main"},
    /*exposes_prometheus_metrics*/ false,
    /*self_manages_downloads*/ false,
    /*takes_args*/ true, ...
};
```

The same object drives `config.json` defaults, CLI flag registration, `/system-info`
and the generated docs — so adding a knob is declarative, but adding a *backend* is not.

**Server** — `src/cpp/server/backends/<name>/<name>_server.cpp`: a
`WrappedServer` subclass (`load()`, `stop()`, `is_backend_alive()`, request
handlers, SSE) plus:

```cpp
std::unique_ptr<WrappedServer> create(const BackendContext& ctx) { return make_server<VLLMServer>(ctx); }
const BackendSpec* spec() { return make_spec<VLLMServer>(descriptor, /*split=*/true); }
const BackendOps*  ops()  { return single_ops<VLLMOps>(); }   // BackendOps: discover_models,
                                                               // is_downloaded, resolve_checkpoint_path,
                                                               // populate_metadata, check_install, ...
```

**Registration** — `CMakeLists.txt`:

```cmake
set(LEMON_BACKENDS
    "llamacpp|llamacpp"
    "vllm|vllm"
    "cloud|cloud"
    ...   # "<recipe>|<stem>"
)
```

`foreach(_backend_entry ${LEMON_BACKENDS})` feeds
`backend_descriptors_generated.h.in`, `backend_factories_generated.h.in` and
`backend_capabilities_generated.h.in`. `BackendRegistration{descriptor, create,
spec, ops}` is then a static table.

**There is no runtime extension point.** Grepping the tree for plugin machinery
returns only `dlopen` calls inside `system_info.cpp` / `platform/*_metrics.h`
(probing ROCm and NVML) — nothing that loads a backend at runtime. A new recipe
means: new C++ files + `LEMON_BACKENDS` + a rebuilt `lemond` + a re-signed
package, forever.

Two more constraints that matter for Gufo specifically:

- `lemond` is a **systemd system service running as user `lemonade`**, with
  `ProtectHome=yes`, `PrivateTmp=yes`, `NoNewPrivileges=yes`. It cannot read
  `~/models` and cannot drive *your* rootless podman (`/run/user/1000`, your
  `subuid` range). A native Gufo backend either needs the hardening relaxed, or
  a rootful podman/socket-activated helper.
- Model lifecycle in Lemonade is **download-oriented**: `lemonade install -m X`
  resolves Hugging Face checkpoints through `BackendOps` (`required_checkpoints`,
  `resolve_checkpoint_path`, `download_model`). Gufo's lifecycle is "a container
  per GGUF file I already have". `self_manages_downloads` and `dynamic_models`
  exist for engines that supply their own models, which is the closer match.

## 2. What Gufo needs

| Need | gufo-cli today |
|---|---|
| Engine transport | one podman container per GGUF, GPU passthrough, `127.0.0.1:<auto port>` |
| Model source | local `**/*.gguf` under `~/models` — nothing to download |
| Memory | unified 123 GB; one 111 GB model can fill the box, so starting model N usually means stopping model N-1 |
| Latency | load takes seconds to minutes; requests must not hang silently |
| Identity | served id is the GGUF's `general.name` (`"Qwen3.8 Flash Next"`), ports drift |

A Lemonade client needs one stable endpoint, a model list that is complete
*before* anything is loaded, and per-model ids that never change.

## 3. The three options

### A — Native C++ `gufo` recipe (fork `lemonade-server`)

Descriptor + server + `LEMON_BACKENDS` entry, `dynamic_models = true`,
`self_manages_downloads = true`, `slot_policy = Standard`,
`support = {{"rocm", BackendTier::Experimental, BackendFormat::Container,
{"linux"}, {{"amd_gpu", {"gfx1151"}}}, "Strix Halo (Gufo engine)"}}`.
(`BackendFormat::Container` already exists in `recipe_backend_def.h` and no
backend uses it yet — the packaging concept is waiting for someone.) `load()` shells out to
`podman run`, `stop()` to `podman rm -f`, `is_backend_alive()` probes
`/v1/models`.

- ✅ Real `gufo` recipe in the UI; slot/LRU handling by Lemonade; `/system-info`
  reports it; single binary.
- ❌ Fork + rebuild + repackage `lemond` on every Lemonade release.
- ❌ Runs as user `lemonade` under `ProtectHome`/`NoNewPrivileges`: needs a
  hardening workaround to reach rootless podman, or a rootful engine.
- ❌ Lemonade's install/download state machine has to be told to no-op
  (`self_manages_downloads`) and its checkpoint model bent to "file in ~/models".
- ❌ Losing Lemonade's own process supervisor for a container supervisor is a
  semantic mismatch it has no hook for.

**Verdict:** the only route to a *named* Gufo backend; not compatible with
"one script, keeps working after Lemonade updates".

### B — Impersonate `llamacpp`

Point Lemonade's existing recipe at a llama.cpp-shaped binary. Gufo speaks an
OpenAI API, not llama.cpp's process contract: Lemonade launches and supervises
the binary itself, resolves `--ctx-size`/`--model` args, parses its health and
`/metrics`. There is no seam to hijack without the same fork as (A). **Rejected.**

### C — Cloud provider + local bridge  ← shipped

Lemonade 11 ships a `cloud` recipe: `lemonade cloud install <provider>
--base-url https://... --api-key ...` registers an OpenAI-compatible upstream,
discovers `<base>/models`, and publishes `<provider>.<model>` in `/v1/models`
with `recipe: cloud` — which the desktop app lists like any other model. Its
descriptor is tiny (`binary: ""`, `dynamic_models: true`,
`slot_policy: Unmetered`), i.e. Lemonade already treats "models live somewhere
else" as a first-class case.

Gufo containers already speak the API. The three gaps are exactly what the
bridge covers:

1. **Nothing is loaded yet** → the bridge advertises every GGUF on disk, always.
2. **Ports are per-container and ephemeral** → one stable endpoint, `:13399`.
3. **Ids are unstable** → the bridge publishes file-derived ids and starts
   containers with `gufo run --served-name <id>` (`gufo serve llm
   --served-model-name`), then rewrites `model` in proxied requests so hand-started
   containers work too.

| | A: native recipe | C: cloud + bridge |
|---|---|---|
| Lemonade rebuild / fork | required | none |
| Survives Lemonade updates | needs re-fork | yes |
| Root / service hardening changes | yes | no (user systemd + rootless podman) |
| Recipe label in UI | `gufo` | `cloud` |
| Cold start | Lemonade's own load UI | bridge starts it, or `gufo-lemonade load` |
| Streaming, tools, reasoning | native | verified through Lemonade |
| Effort | C++ + packaging + maintenance | ~1k-line stdlib Python script |

**Costs we accept:** requests to a cold model pay container startup (Lemonade's
cloud timeout applies, hence the explicit `503 still loading` answer and the
`load`/`autostart` commands); models are labelled `cloud`; `cloud` is flagged
experimental upstream; slot management is the bridge's `max_loaded`, not
Lemonade's LRU (which is arguably right, since Gufo memory behaviour is
container-shaped).

## 4. Blueprint, if you want the native recipe later

The bridge is deliberately structured as the C++ port would be, so the mapping is
mechanical:

| Bridge component (`bin/gufo-lemonade`) | Native equivalent |
|---|---|
| `Catalog.scan()` | `GufoOps::discover_models()`, `is_downloaded()` |
| `Catalog` id/title/ctx rules | `GufoOps::populate_metadata()`, `resolve_checkpoint_path()` |
| `Engine._start_locked()` (`gufo run`) | `GufoServer::load()` (`podman run`) |
| `Engine.evict*` | `SlotPolicy::Standard` + `BackendManager` eviction |
| `Registrar` | not needed (the recipe *is* the registration) |
| `_forward` model rewrite | `--served-model-name`, so unnecessary |
| `/v1/models` cards | `GufoServer::get_models()` |

Steps:

1. `src/cpp/include/lemon/backends/gufo/gufo.h` — descriptor (recipe `gufo`,
   `binary: ""` since podman is the launcher, `dynamic_models: true`,
   `self_manages_downloads: true`, `uses_ctx_size: true`, `takes_args: true` for
   `gufo_args`, `rocm_requires_cwsr_fix: true` like the other gfx1151 ROCm
   backends, `support` limited to `{"linux"}` × `gfx1151`, `supported_modes`
   `{"chat"}`).
2. `src/cpp/server/backends/gufo/gufo_server.{h,cpp}` — `WrappedServer`
   subclass; copy the HTTP/SSE plumbing shape from `cloud_server.cpp` and the
   subprocess handling from `llamacpp_server.cpp`; export `create()`, `spec()`,
   `ops()`.
3. `CMakeLists.txt`: `set(LEMON_BACKENDS ... "gufo|gufo")`.
4. Process/user model: either relax `lemond.service` hardening (bad) or have the
   backend talk to a small per-user socket-activated `gufo-orchestrator` — which
   is essentially this bridge, minus the OpenAI surface. That split is the
   honest way to keep podman rootless.
5. Docs/UI: `server_models.json` needs no entries (`dynamic_models`), but the
   generated support matrix picks the recipe up from `web_display_name`.
6. Upstream it as a PR; otherwise budget a rebase per Lemonade release.

Until that exists, the `cloud` route gives the same user-visible outcome with no
fork — which is why it is the shipped design.
