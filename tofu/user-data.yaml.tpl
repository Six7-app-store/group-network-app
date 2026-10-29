#cloud-config
ssh_pwauth: true
disable_root: true
package_update: true
packages:
  - openssh-server
  - iputils-ping
  - python3-yaml
  - netplan.io
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
      import time
      import yaml
      def interface_id(mac):
          # A dual-stack access NIC is attached after Nova creates the VM.
          for attempt in range(61):
              interfaces = [p.parent.name for p in pathlib.Path('/sys/class/net').glob('*/address')
                            if p.read_text().strip().lower() == mac.lower()]
              if len(interfaces) == 1:
                  break
              if attempt == 60:
                  raise RuntimeError('Expected exactly one configured interface within 120 seconds')
              time.sleep(2)
          nic = interfaces[0]
          candidates = set()
          for filename in glob.glob('/etc/netplan/*.yaml'):
              config = yaml.safe_load(pathlib.Path(filename).read_text()) or {}
              for name, settings in config.get('network', {}).get('ethernets', {}).items():
                  if (settings.get('match', {}).get('macaddress', '').lower() == mac.lower()
                          or name == nic or settings.get('set-name') == nic):
                      candidates.add(name)
          if len(candidates) > 1:
              raise RuntimeError('Ambiguous interface configuration')
          return next(iter(candidates), nic)
      lab = {'match': {'macaddress': '${lab_mac}'}, 'addresses': ${jsonencode(lab_addresses)},
             'dhcp4': False, 'dhcp6': False, 'accept-ra': False}
      if ${lab_mtu} > 0:
          lab['mtu'] = ${lab_mtu}
      ethernets = {interface_id('${lab_mac}'): lab}
%{ if secondary_mac != "" ~}
      secondary = {'match': {'macaddress': '${secondary_mac}'},
                   'addresses': ['${secondary_address}'],
                   'dhcp4': False, 'dhcp6': False, 'accept-ra': False,
                   'routes': [{'to': '${secondary_cidr}', 'scope': 'link', 'table': 100}],
                   'routing-policy': [{'from': '${split("/", secondary_address)[0]}/32', 'table': 100, 'priority': 100}]}
      if ${secondary_mtu} > 0:
          secondary['mtu'] = ${secondary_mtu}
%{ if secondary_gateway != "none" ~}
      secondary['routes'].append({'to': '0.0.0.0/0', 'via': '${secondary_gateway}', 'table': 100})
%{ endif ~}
      ethernets[interface_id('${secondary_mac}')] = secondary
%{ endif ~}
      config = {'network': {'version': 2, 'ethernets': ethernets}}
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
