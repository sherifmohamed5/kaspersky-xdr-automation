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
