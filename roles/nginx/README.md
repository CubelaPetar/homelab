# Auto Homepage setup

This ansible project automatically sets up a vps.
It sets up:

- [x] essential security configs
  - package updates and installations
  - users and permissions
  - sets up a firewall (`ufw`)
  - strengthens `ssh` config
  - installs `ntp`
- [x] web server(`nginx`)
- [ ] nextcloud instance
- [ ] git server
- [ ] mail server

## Requirements

- VPS with minimally
  - 2GB of RAM
  - 2 CPU
- Configure A and AAAA records for your domain

  | Host | Type | Destination |
  | ---- | ---- | ----------- |
  | @    | A    | YourIPv4    |
  | @    | AAAA | YourIPv6    |
  | \*   | A    | YourIPv4    |
  | \*   | AAAA | YourIPv6    |
  | www  | A    | YourIPv4    |
  | www  | AAAA | YourIPv6    |

## Usage

```sh
ansible-playbook run.yml -K
```

## TODO

- include auto SSL certs creation with `letsencrypt`
- use `swag` or similar with docker (auto SSL included)

## Bugs

- ansible freezes after enabling `ufw` the first time
