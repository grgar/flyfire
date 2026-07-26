<div align="center">

# flyfire

| <sub><img src="https://firefly-iii.org/assets/favicon/favicon.ico" width="24"></sub> [firefly](https://firefly-iii.org) on <sub><img src="https://fly.io/static/images/favicon/favicon.ico" width="24"></sub> [fly.io](https://fly.io) |
|:-:|
|Deploys Firefly-iii and Data Importer as Fly machines.<br>|

</div>

> [!Note]
> I'm not affiliated with Firefly nor Fly.io.

> [!Warning]
> This was not originally written to be shared and makes lots of assumptions, many of which I have forgotten I made. It's not expected to work out of the box for you yet, though improvements may be made in the future. It should serve as a useful starting point for your own fork though.

Fly.io is my preferred method for deploying Firefly as

- ✅ fly.io can be very cheap through the support of autostart so the machines stop when not accessed for a while, saving money
  (learn more about this behaviour at [fly.io / Fly Launch / Autostop/autostart Machines](https://fly.io/docs/launch/autostop-autostart/))
- ✅ has 'free' backups of the storage

Flyfire configures the following on top of a default setup:

- ⚙️ merges Firefly-iii and Data Importer into a single image, differentiated by Host header
- ⚙️ SQLite database in persistent storage volume
- ⚙️ php `opcache.jit` and️ nginx `fastcgi_buffering off;` for performance
- ⚙️ the Data Importer alongside Firefly, preconfigured with knowledge of where Firefly and how to internally communicate with it, but using OAuth for authorisation
- ⚙️ `ALLOWED_HOSTS` to restrict access to a custom domain
- ⚙️ automatic upgrading of database when a new version is deployed
- ⚙️ optional [MCP server](https://github.com/etnperlong/firefly-iii-mcp) at `/mcp` so AI assistants can manage Firefly over its API

**To deploy your own instance**, create an account on fly.io, then

1. Fork this repository.
2. `brew install flyctl`
3. `fly launch --no-deploy`
4. `fly deploy --ha=false`
5. `cp .env{.example,}` and edit `.env`
6. `fly secrets import <.env`

**To enable the MCP server**, so MCP clients (Claude, etc.) can read and write your Firefly data:

1. In Firefly, create a Personal Access Token under Options → Profile → OAuth.
2. Generate a separate bearer token for the MCP endpoint, e.g. `openssl rand -hex 32`. nginx checks this token before anything reaches the MCP server, so the endpoint is unusable without it; if either secret is unset the MCP server is not started at all.
3. `fly secrets set FIREFLY_III_PAT=<token from step 1> MCP_TOKEN=<token from step 2>`
4. Point your MCP client at `https://<FIREFLY_HOST>/mcp` (Streamable HTTP transport) with header `Authorization: Bearer <MCP_TOKEN>`.

The MCP server ([`@firefly-iii-mcp/server`](https://github.com/etnperlong/firefly-iii-mcp)) runs inside the same machine, listening only on localhost and talking to Firefly over the loopback nginx, so requests to `/mcp` wake a stopped machine like any other traffic and nothing else needs to be deployed. To trim the ~90 registered tools to a smaller set, add `--preset` or `--tools` flags in `entrypoint.sh` (see the [upstream docs](https://github.com/etnperlong/firefly-iii-mcp#tool-presets)).

This repository contains GitHub Actions that deploy updates pushed to main, once your initial deployment is complete. For these actions to work, flyctl needs authenticating in GitHub: run `fly tokens create deploy` locally and set `FLY_API_TOKEN` to this value in the repository settings.

**To run locally** for development/testing, on macOS with apple/container,

```sh
container build -t flyfire:latest
container run --rm -p 8080:8080 --name flyfire --env-file .env -d -v storage:/var/www/html/storage flyfire:latest
```

If oauth-private.key cannot be found

```
container exec -it flyfire php artisan correction:restore-oauth-keys
container exec -it flyfire chown www-data:nginx storage/oauth-{private,public}.key
```
