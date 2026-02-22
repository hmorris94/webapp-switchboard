"""WebApp Switchboard — composes Flask Blueprints from sibling projects."""

import importlib
import importlib.util
import sys
from pathlib import Path
from flask import Flask, render_template
from werkzeug.middleware.proxy_fix import ProxyFix

ROOT = Path(__file__).resolve().parent.parent

# ---------------------------------------------------------------------------
# Project registry
#
# Projects are defined in projects_local.py (gitignored).
# Copy projects_template.py to projects_local.py to get started.
# ---------------------------------------------------------------------------

try:
    from projects_local import PROJECTS
except ImportError:
    from projects_template import PROJECTS


def _load_blueprint(project_dir, module_name, blueprint_module=None):
    """Import a blueprint from *project_dir*.

    Each sibling project has its own ``blueprint.py``.  Using importlib with a
    unique module name per project avoids the name-collision problem that would
    arise from three modules all called ``blueprint``.

    The project directory is added to sys.path so that the blueprint's own
    local imports (e.g. ``from data_manager import DataManager``) resolve
    correctly — both at load time and for lazy imports inside route handlers.

    When *blueprint_module* is given (e.g. ``"app.blueprint"``), the blueprint
    lives inside a package and is loaded with proper package semantics so that
    relative imports work.
    """
    project_dir_str = str(project_dir)
    if project_dir_str not in sys.path:
        sys.path.insert(0, project_dir_str)

    if blueprint_module is None:
        # Standalone blueprint.py at project root
        bp_path = project_dir / "blueprint.py"
        spec = importlib.util.spec_from_file_location(module_name, bp_path)
        module = importlib.util.module_from_spec(spec)
        # Register in sys.modules so Flask can resolve the module's root path
        # (needed for template_folder / static_folder lookups).
        sys.modules[module_name] = module
        spec.loader.exec_module(module)
        return module

    # Package-based blueprint (e.g. "app.blueprint")
    parts = blueprint_module.split(".")
    pkg_dir = project_dir / parts[0]
    unique_pkg = f"_switchboard_pkg_{module_name}"

    # Load the parent package with a unique name so relative imports resolve
    # and multiple projects with an "app" package don't collide.
    pkg_spec = importlib.util.spec_from_file_location(
        unique_pkg,
        pkg_dir / "__init__.py",
        submodule_search_locations=[str(pkg_dir)],
    )
    pkg_mod = importlib.util.module_from_spec(pkg_spec)
    sys.modules[unique_pkg] = pkg_mod
    pkg_spec.loader.exec_module(pkg_mod)

    # The submodule is typically already loaded as a side effect of
    # __init__.py's own imports; return it from sys.modules.
    sub_name = f"{unique_pkg}.{parts[1]}"
    if sub_name in sys.modules:
        return sys.modules[sub_name]

    # Fallback: load the submodule explicitly
    bp_spec = importlib.util.spec_from_file_location(
        sub_name, pkg_dir / f"{parts[1]}.py",
    )
    bp_mod = importlib.util.module_from_spec(bp_spec)
    bp_mod.__package__ = unique_pkg
    sys.modules[sub_name] = bp_mod
    bp_spec.loader.exec_module(bp_mod)
    return bp_mod


def create_app(projects=None, config=None):
    """Application factory.

    Parameters
    ----------
    projects : list[dict] | None
        Override the default PROJECTS registry (useful for testing or
        running a subset).
    config : dict | None
        Optional Flask config overrides.
    """
    projects = projects if projects is not None else PROJECTS
    app = Flask(__name__, template_folder=str(Path(__file__).parent / "templates"))
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)

    if config:
        app.config.update(config)

    registered = []
    for proj in projects:
        try:
            project_dir = ROOT / proj["directory"]
            bp_module = _load_blueprint(
                project_dir,
                f"_switchboard_bp_{proj['name']}",
                blueprint_module=proj.get("blueprint_module"),
            )
            bp_config = proj.get("blueprint_config")
            bp = bp_module.create_blueprint(
                name=proj["name"],
                config=bp_config,
            )
            app.register_blueprint(bp, url_prefix=proj["url_prefix"])
            registered.append(proj)

            # Start background tasks when server-side mode is enabled
            if bp_config and bp_config.get("server_side"):
                pkg_name = f"_switchboard_pkg__switchboard_bp_{proj['name']}"
                try:
                    bg_module = importlib.import_module(f"{pkg_name}.background")
                    bg_module.start_background_tasks()
                except (ImportError, AttributeError):
                    pass

        except Exception as exc:
            print(
                f"WARNING: failed to load project '{proj['name']}': {exc}",
                file=sys.stderr,
            )

    @app.route("/")
    def landing():
        return render_template("landing.html", projects=registered)

    return app
