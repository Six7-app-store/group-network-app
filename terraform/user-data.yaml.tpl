#cloud-config
ssh_pwauth: true
disable_root: true
users:
%{ for user in team_users ~}
  - name: ${user.username}
    lock_passwd: false
    shell: /bin/bash
%{ endfor ~}
chpasswd:
  expire: false
  users:
%{ for user in team_users ~}
    - name: ${user.username}
      password: ${user.password}
      type: text
%{ endfor ~}
write_files:
  - path: /usr/local/sbin/configure-group-lab.py
    permissions: '0700'
    content: |
      import glob
      import pathlib
      import yaml
      mac = '${lab_mac}'.lower()
      # Reuse the generated netplan ID so there are no duplicate MAC matches.
      interfaces = [p.parent.name for p in pathlib.Path('/sys/class/net').glob('*/address')
                    if p.read_text().strip().lower() == mac]
      if len(interfaces) != 1:
          raise RuntimeError('Expected exactly one exercise interface')
      nic = interfaces[0]
      candidates = set()
      for filename in glob.glob('/etc/netplan/*.yaml'):
          config = yaml.safe_load(pathlib.Path(filename).read_text()) or {}
          for name, settings in config.get('network', {}).get('ethernets', {}).items():
              if (settings.get('match', {}).get('macaddress', '').lower() == mac
                      or name == nic or settings.get('set-name') == nic):
                  candidates.add(name)
      if len(candidates) > 1:
          raise RuntimeError('Ambiguous exercise interface configuration')
      name = next(iter(candidates), nic)
      config = {'network': {'version': 2, 'ethernets': {name: {
          'match': {'macaddress': mac}, 'addresses': ['${lab_ip}/24'],
          'dhcp4': False, 'dhcp6': False, 'accept-ra': False}}}}
      target = pathlib.Path('/etc/netplan/99-group-lab.yaml')
      target.write_text(yaml.safe_dump(config))
      target.chmod(0o600)
  - path: /etc/ssh/sshd_config.d/00-group-lab.conf
    permissions: '0644'
    content: |
      PasswordAuthentication yes
      PermitRootLogin no
runcmd:
  - [python3, /usr/local/sbin/configure-group-lab.py]
  - [netplan, apply]
%{ for user in team_users ~}
  - [chmod, '0700', '/home/${user.username}']
%{ endfor ~}
  - [systemctl, enable, --now, ssh]
  - [systemctl, restart, ssh]
