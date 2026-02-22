#!/usr/bin/env python3
"""WebApp Switchboard — single entry point.

Subcommands:
    web    Start the WebApp Switchboard server (all projects)
"""

import argparse
from app import create_app, PROJECTS


def main():
    parser = argparse.ArgumentParser(description="WebApp Switchboard server")
    subparsers = parser.add_subparsers(dest="command")

    web_parser = subparsers.add_parser("web", help="Start the WebApp Switchboard web server")
    web_parser.add_argument("--host", default="0.0.0.0", help="Bind address")
    web_parser.add_argument("--port", type=int, default=8080, help="Port")

    args = parser.parse_args()

    if args.command == "web":
        app = create_app()

        print(f"WebApp Switchboard starting on http://{args.host}:{args.port}")
        print("Registered projects:")
        for proj in PROJECTS:
            print(f"  {proj['url_prefix']:12s} -> {proj['display_name']}")
        print()

        app.run(host=args.host, port=args.port)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
