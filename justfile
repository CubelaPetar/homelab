#!/usr/bin/env -S just --justfile

# Ansible playbook against specific host
run HOST *TAGS:
  ansible-playbook -b run.yml --limit {{HOST}} {{TAGS}}

# docker compose against remote host via Ansible
compose HOST *V:
  ansible-playbook run.yml --limit {{HOST}} --tags compose {{V}}


# optionally use --force to force reinstall all requirements
reqs *FORCE:
	ansible-galaxy install -r requirements.yml {{FORCE}}

# just vault (encrypt/decrypt/edit)
vault ACTION:
    EDITOR=nvim ansible-vault {{ACTION}} group_vars/secrets.yml
