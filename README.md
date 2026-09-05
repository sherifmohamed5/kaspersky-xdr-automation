# Kaspersky Next XDR & KUMA All-in-One Automation Tool

Automated single-node deployment tool for Kaspersky Next XDR Expert, KUMA, PostgreSQL 16, and Kubernetes on Ubuntu 22.04 and 24.04 LTS.

## Quick Start (One-Liner)

Run the following command on a fresh Ubuntu server as root:

```bash
mkdir -p /root/XDR && cd /root/XDR && \
curl -sSL -O [https://raw.githubusercontent.com/](https://raw.githubusercontent.com/)<YOUR_USERNAME>/kaspersky-xdr-automation/main/xdr_all_in_one.sh && \
curl -sSL -O [https://raw.githubusercontent.com/](https://raw.githubusercontent.com/)<YOUR_USERNAME>/kaspersky-xdr-automation/main/config.env && \
chmod +x xdr_all_in_one.sh && \
./xdr_all_in_one.sh


---

sudo passwd root

Ka5per$Ky
Ka5per$Ky
su - root
Ka5per$Ky
mkdir script
cd script

curl -L "https://box.kaspersky.com/seafhttp/f/742909caf9b74d66826b/?op=view" -o xdr_all_in_one.sh -L "https://box.kaspersky.com/seafhttp/f/6848c1ef2f7d4cbd99d1/?op=view" -o config.env

chmod +x xdr_all_in_one.sh

./xdr_all_in_one.sh

