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

- ⚙️ SQLite database in persistent storage volume
- ⚙️ php `opcache.jit` and️ nginx `fastcgi_buffering off;` for performance
- ⚙️ the Data Importer alongside Firefly, preconfigured with knowledge of where Firefly and how to internally communicate with it, but using OAuth for authorisation
- ⚙️ `ALLOWED_HOSTS` to restrict access to a custom domain
- ⚙️ automatic upgrading of database when a new version is deployed

**To deploy your own instance**, create an account on fly.io, then

1. Fork this repository.
2. `brew install flyctl`
3. `fly launch --no-deploy`
4. `fly deploy --ha=false`
5. `cp .env{.example,}` and edit `.env`
6. `fly secrets import <.env`

This repository contains GitHub Actions that deploy updates pushed to main, once your initial deployment is complete. For these actions to work, flyctl needs authenticating in GitHub: run `fly tokens create deploy` locally and set `FLY_API_TOKEN` to this value in the repository settings.

To ensure Firefly autostarts from the Data Importer requests, use a .flycast address rather than an .internal address for communication between:

1. `fly ips allocate-v6 --private`
2. Update `importer/.env`'s `FIREFLY_III_URL`

   ```diff
   -FIREFLY_III_URL=http://your-app-name.internal
   +FIREFLY_III_URL=http://your-app-name.flycast
   ```
