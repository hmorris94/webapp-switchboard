"""Gunicorn configuration for WebApp Switchboard."""

bind = "unix:/run/switchboard/gunicorn.sock"
wsgi_app = "app:create_app()"

workers = 2
worker_class = "sync"

# Longer than a single-project app: startup loads all blueprints
timeout = 60
graceful_timeout = 10

accesslog = "-"
errorlog = "-"
loglevel = "info"

proc_name = "switchboard"

# Load all blueprints once in the master process; workers inherit via fork.
# Memory-efficient and ensures requests are served from a warm application.
preload_app = True
