#!/usr/bin/env bash
rm -rf /etc/systemd/system/httpd.service.d; systemctl daemon-reload; systemctl restart httpd
setenforce 1; chmod 644 /etc/httpd/conf/httpd.conf
firewall-cmd -q --add-service=http; firewall-cmd -q --add-service=ssh
rm -f /var/lib/rewind/pending; echo 0 > /var/lib/rewind/strikes
rewind snapshot >/dev/null 2>&1 && : > /var/lib/rewind/timeline
rewind status && systemctl is-active rewind-drift.timer && echo "DEMO READY: $(systemctl show httpd -P MemoryMax)"
