# Backups and restore

A complete Hub backup contains:

```text
Hub data
  +-- SQLite databases
  +-- Build files and screenshots
  +-- learning stores
  +-- encrypted GitHub App configuration

Separate secret backup
  +-- database encryption keys
  +-- deployment secrets
```

Back up the Hub data at one consistent point so database records do not refer to missing Build files. Store the secret backup separately with the same retention and access controls.

Local Build files live under `REPLICA_ARTIFACT_ROOT`, which defaults to `storage/artifacts`. [Learning stores](learnings.md#operations) live under `REPLICA_LEARNING_ROOT`, which defaults to `storage/learning`.

To restore Hub:

1. Restore every SQLite database.
2. Restore artifact storage and the learning stores.
3. Restore the encryption keys and deployment secrets.
4. Check that Hub can read the App credentials:

```sh
bin/devcontainer exec bin/rails replica:github:diagnose
```
