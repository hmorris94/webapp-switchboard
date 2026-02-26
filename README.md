# WebApp Switchboard

A (frequently Flask) blueprint compositor that combines multiple personal web projects into a single server. Each project runs at its own URL prefix and the landing page at `/` lists them all.

## Running locally

```bash
pip install -r requirements.txt
python main.py web
```

Opens at `http://localhost:8080`.

## Adding a project

1. The project must expose `app/blueprint.py` with a `create_blueprint(name, config=None)` factory.
2. Append an entry to `PROJECTS` in `projects_local.py`:

```python
{
    "name": "myproject",
    "directory": "My-Project-Dir",       # sibling directory at ../
    "url_prefix": "/myproject",
    "display_name": "My Project",
    "description": "One sentence.",
    "blueprint_module": "app.blueprint",
    "blueprint_config": None,
}
```

3. That's it — restart the server.

## VPS deployment

See `VPS_SETUP.md` for the full operational guide. The `deploy/` directory contains all deployment assets.

Quick start on a fresh Ubuntu 25.04+ VPS (nginx 1.25+ required for HTTP/3):

```bash
cp deploy/config.template.sh deploy/config.local.sh
# edit config.local.sh — fill in DOMAIN, CERTBOT_EMAIL, SWITCHBOARD_USER, and repo URLs
sudo bash deploy/setup.sh
```

To deploy updates from your local machine:

```bash
bash deploy/deploy.sh
```
