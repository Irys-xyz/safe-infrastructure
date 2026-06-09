# Ansible: deploy and manage the Irys Safe{Wallet} stack

`irys-safe.yml` installs, starts, stops, and restarts the self-hosted Safe{Wallet}
stack for Irys Mainnet (chain 3282) on a Debian host. It runs the stack as a rootless
podman `systemd --user` service (the same context the stack is built and tested in),
reusing `scripts/run_locally_podman.sh` for the bring-up and `docker compose down` for
teardown.

## Layout

| File | Purpose |
| --- | --- |
| `irys-safe.yml` | The playbook (install / start / stop / restart). |
| `inventory.example.ini` | Inventory template — copy to `inventory.ini`. |
| `vars.example.yml` | Variables — copy to `vars.yml` and vault the secrets. |
| `templates/env.j2` | Renders the repo-root `.env` on the host. |
| `templates/irys-safe.service.j2` | Renders the systemd user unit (paths set to `irys_dir`). |

## Prerequisites

- **Control node:** `ansible-core` ≥ 2.16, the `ansible.posix` collection
  (`ansible-galaxy collection install -r requirements.yml`), and `rsync`.
- **Target:** Debian 12/13 with SSH access and a sudo-capable login. Connect as the runtime
  user (`ansible_user` = `stack_user`) so rsync can write the deploy dir. The host needs
  ≥ 16 GiB RAM and ~10 GiB free disk — the first start builds the custom UI image
  (`next build` spikes 4–8 GiB) and pulls several GB (RUNBOOK §10).

## Configure

```bash
ansible-galaxy collection install -r requirements.yml   # ansible.posix (rsync module)
cp inventory.example.ini inventory.ini      # set ansible_host / ansible_user (= stack_user)
cp vars.example.yml vars.yml                # set stack_user, RPC, version pins
ansible-vault encrypt_string 's3cret' --name irys_cfg_superuser_password   # vault any secrets
```

The playbook deploys this working copy to the host with **rsync**
(`ansible.posix.synchronize`), shipping your local tree as-is — uncommitted changes
included, no git push needed. It excludes `.git`, `data/`, `.env`, `claude/`, and the
Ansible local files, then chowns the tree to `stack_user`. Override the source with
`irys_src_dir` to push a different checkout.

## Run

```bash
ansible-playbook -i inventory.ini irys-safe.yml -e @vars.yml                       # install + start
ansible-playbook -i inventory.ini irys-safe.yml -e @vars.yml -e irys_action=start
ansible-playbook -i inventory.ini irys-safe.yml -e @vars.yml -e irys_action=stop    # keeps databases
ansible-playbook -i inventory.ini irys-safe.yml -e @vars.yml -e irys_action=restart
ansible-playbook -i inventory.ini irys-safe.yml -e @vars.yml -e irys_action=status  # read-only health check
```

`install` is long on first run (image pulls + UI build); the task blocks until the
bring-up finishes. Watch progress on the host with
`journalctl --user -u irys-safe -f` (as `stack_user`). `stop` and `restart` map to
`systemctl --user`; neither runs `down -v`, so the `./data` Postgres volumes persist.
`status` is read-only — it prints the unit's active state and the §9 endpoint status
codes (`/cfg`, `/txs`, `/cgw`, `/`) without changing anything.

## Secrets

`.env` (compose project name, ports, image tags, gateway URL) is rendered from `vars.yml`
(vault the admin passwords). The per-service `container_env_files/*.env` hold real secrets
and are **gitignored** — only the committed `*.env.example` templates carry their shape.
This playbook **does not sync them** (`--exclude=container_env_files/*.env`) and fails fast
before start if any are missing.

Provision them out-of-band on the host, in `<stack_home>/irys-safe-infrastructure/container_env_files/`:
copy each `*.env.example` to `*.env` and fill the `__CHANGE_ME__` / `__PASSWORD__` placeholders.
They persist across deploys (rsync leaves them untouched), so `restart`/redeploy will not clobber
rotated values. Rotate before any production use and never commit the real files (RUNBOOK §2, §10).

## Reference

Operations, chain configuration, and troubleshooting: `RUNBOOK.md` (§11 for first-boot
issues, §12 for the systemd unit this playbook installs).
