#cloud-config
package_update: true
package_upgrade: true

packages:
  - haproxy

write_files:
  - path: /etc/haproxy/haproxy.cfg
    content: |
      ${haproxy_cfg}
    owner: root:root
    permissions: "0644"

runcmd:
  - systemctl enable haproxy
  - systemctl restart haproxy
