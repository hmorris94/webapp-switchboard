"""Project registry template — committed, contains no real project details.

Copy this file to projects_local.py (gitignored) and fill in your projects.
projects_local.py is loaded automatically by app.py if present.

Each entry in PROJECTS must have:
    name            Short identifier. Used in Blueprint name and url_for().
    directory       Sibling directory name at ../ (must match the actual folder).
    url_prefix      URL mount point, e.g. "/myproject".
    display_name    Shown on the landing page.
    description     One-sentence description shown on the landing page.
    blueprint_module  Module path to the blueprint. Always "app.blueprint" for
                    projects following the standard structure.
    blueprint_config  Dict of config overrides passed to create_blueprint(), or
                    None. Common keys:
                        server_side (bool) — start background data-fetch threads
                        data_dir (str)     — override default data directory path
"""

PROJECTS = [
    {
        "name": "example",
        "directory": "My-Project",
        "url_prefix": "/example",
        "display_name": "Example Project",
        "description": "A short description of what this project does.",
        "blueprint_module": "app.blueprint",
        "blueprint_config": None,
    },
]
