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

**To enable the MCP server**, so MCP clients can read and write your Firefly data, create a Personal Access Token in Firefly under Options → Profile → OAuth and set it as a secret:

```sh
fly secrets set FIREFLY_III_PAT=<token>
```

That's all that's needed — `/mcp` is then served on the Firefly host over Streamable HTTP. Nothing reaches the MCP server without passing one of two authorisation checks in nginx.

*OAuth* (for clients that only take a client ID and secret, such as Claude Desktop and Cowork). Firefly is its own OAuth authorisation server via Laravel Passport, so it issues the credentials itself — no separate identity provider:

1. In Firefly, Options → Profile → OAuth → Clients → Create new client, with redirect URL `https://claude.ai/api/mcp/auth_callback`.
2. In the client, add a custom connector for `https://<FIREFLY_HOST>/mcp` and put the client ID and secret into its advanced/OAuth settings.
3. Approve the connection in the browser window Firefly opens.

The client discovers the rest through `/.well-known/oauth-protected-resource` and `/.well-known/oauth-authorization-server`, which nginx serves. Tokens are issued, scoped, expired and revoked by Firefly, so access can be withdrawn at any time from Options → Profile → OAuth without redeploying.

*Static token* (for CLI clients and scripts that send a header directly). Set `MCP_TOKEN` to a random value, e.g. `openssl rand -hex 32`, and send it as `Authorization: Bearer <MCP_TOKEN>`. Leave `MCP_TOKEN` unset to disable this path entirely — the entrypoint then substitutes a random value that no client can send.

The MCP server ([`@firefly-iii-mcp/server`](https://github.com/etnperlong/firefly-iii-mcp)) runs inside the same machine, listening only on localhost and talking to Firefly over the loopback nginx, so requests to `/mcp` wake a stopped machine like any other traffic and nothing else needs to be deployed. To trim the ~90 registered tools to a smaller set, add `--preset` or `--tools` flags in `entrypoint.sh` (see the [upstream docs](https://github.com/etnperlong/firefly-iii-mcp#tool-presets)).

> [!Note]
> The MCP server holds a single PAT and acts as its owner for every request, because it has no per-request authorisation of its own. On a multi-user instance that means any account able to obtain a token could reach the PAT owner's data, so point `MCP_AUTH_PROBE` at a URL only the intended user can read (an owned account, say `http://localhost:8080/api/v1/accounts/1`) instead of the default `/api/v1/about/user`, which merely proves the token is valid.

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
