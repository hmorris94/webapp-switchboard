# WebApp Switchboard — Claude Instructions

## What this is

A Flask blueprint compositor. It dynamically loads sibling projects as blueprints and mounts them at configured URL prefixes under a single web server. The landing page at `/` lists all registered projects.

## Project structure

```
webapp-switchboard/
├── app.py              # create_app() factory + _load_blueprint() + PROJECTS import
├── main.py             # CLI entry point: `python main.py web`
├── requirements.txt    # Shared deps for WebApp Switchboard + all projects
├── projects_template.py # Committed — one generic example entry, field reference
├── projects_local.py   # Gitignored — real project list (create from template)
├── templates/
│   └── landing.html    # Landing page, driven by PROJECTS list
├── deploy/
│   ├── config.template.sh   # Committed template — placeholders only
│   ├── config.local.sh      # Gitignored — real server values (user creates this)
│   ├── setup.sh             # One-time VPS bootstrap (sources config.local.sh)
│   ├── deploy.sh            # Rolling update from local machine (sources config.local.sh)
│   ├── switchboard.service  # systemd unit template (placeholders filled by setup.sh)
│   ├── gunicorn.conf.py     # Gunicorn: Unix socket, 2 workers, preload_app
│   └── nginx.conf           # nginx: HTTP→HTTPS redirect + reverse proxy template
└── VPS_SETUP.md        # Operational VPS setup guide
```

Sibling projects live at `../` relative to the webapp-switchboard directory and are referenced by directory name in `PROJECTS`.

## Key patterns

### Adding a project

Append one dict to `PROJECTS` in `projects_local.py`:

```python
{
    "name": "myproject",              # short identifier, used in Blueprint name + url_for
    "directory": "My-Project-Dir",    # sibling directory name (must exist at ../)
    "url_prefix": "/myproject",       # mount point
    "display_name": "My Project",     # shown on landing page
    "description": "One sentence.",   # shown on landing page
    "blueprint_module": "app.blueprint",  # always this for standard projects
    "blueprint_config": None,         # or dict of overrides passed to create_blueprint()
}
```

The project must have `app/blueprint.py` exporting `create_blueprint(name, config=None)`.

### Blueprint loading

`_load_blueprint()` in `app.py` uses importlib to load each project's blueprint with a unique module name (`_switchboard_pkg_<name>`) to prevent collisions between multiple projects that all have an `app/` package. Do not change this mechanism without understanding the collision problem it solves.

### Background tasks

If `blueprint_config["server_side"] = True`, WebApp Switchboard attempts to import `<pkg>.background` and call `start_background_tasks()`. With `preload_app = True` in Gunicorn, this runs in the master process; workers inherit the app via fork but not the threads.

### projects_local.py and deploy/config.local.sh

Both are gitignored and never committed. Created by copying their respective `*.template.*` counterparts. `projects_local.py` holds the real PROJECTS list; `config.local.sh` holds server IPs, domain, and repo URLs. Both must exist on the VPS as well — they are not deployed by git, they are placed there manually.

## Running locally

```bash
python main.py web          # starts on http://0.0.0.0:8080
python main.py web --port 5000
```

## What NOT to do

- Do not hardcode real project names, server IPs, domain names, or repo URLs in committed files — they belong in `projects_local.py` and `deploy/config.local.sh` only
- Do not change the `_load_blueprint()` importlib mechanism without understanding why unique package names are required
- Do not add project-specific logic to WebApp Switchboard — each project is self-contained in its own blueprint
