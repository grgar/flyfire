This import folder is used to store configuration files to enable automated importing.

1. Link files into directory named *n*.json.
2. Set as secrets

    ```sh
    find import -name "*.json" -exec sh -c 'echo CFG_$(basename {} | cut -d. -f1)=$(base64 -i {})' \; | xargs fly secrets set
    ```

3. Update [fly.toml](../fly.toml) with sufficient `[[files]]` entries.

    ```toml
    [[files]]
    guest_path = "/import/n.json"
    secret_name = "CFG_n"
    ```
